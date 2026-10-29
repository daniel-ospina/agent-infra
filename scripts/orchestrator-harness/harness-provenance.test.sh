#!/usr/bin/env bash
# harness-provenance.test.sh — the DEPLOY half of "which commit is this box running?": a record that
# names the commit and the bytes, and a deploy that REFUSES to overwrite a patch it did not write.
#
# ── THE TWO MEASURED INCIDENTS (2026-10-28, 2026-10-29) ─────────────────────────────────────────
#   * Box A (macOS, 2026-10-28): a hand-applied fix to `$O/merge-one.sh` was REVERTED TWICE by
#     redeploys — the file's mtime moved at 20:02 and again at 20:15, after the patch — so the box ran
#     unpatched code and a production fix looked like it had "stopped working". Nothing printed what was
#     about to be lost; nothing refused.
#   * Box B (2026-10-29): `harness=diverged:5712e52776c8` — `~/orchestrator/orch-loop.sh` was not
#     byte-identical to the checkout, so a diagnosis made against the checkout described code the box
#     was not running. There was no artifact that said WHICH COMMIT the deployed tree claimed to be.
#
# ── WHAT THIS SUITE GRADES, AND WHERE THE CHECK'S OWN VERDICTS ARE GRADED ────────────────────────
# Here: the WRITER (`harness-provenance.sh write|check|show`), the REFUSAL in `deploy-harness.sh`, and
# the `--dry-run`/refusal path of `deploy-mac-orchestrator.sh` — which is run ONLY as a dry run, because
# the real thing would overwrite this box's live `$O`, the exact incident being fixed.
# `check-deployed-drift.sh`'s OWN verdicts with a provenance record (§5-§9 of
# `check-deployed-drift.test.sh`) are graded in that suite, next to the check they are about; the exit-code
# arms shared with `selftest.sh` stay there too. No arm is implemented twice.
#
# Every script driven here is the SHIPPED one — no fixture re-implements the record format, the
# manifest, or the refusal — so a change to the format that only the test knows about is a red.
# ⛔ NO `printf … | grep -q …` (SIGPIPE false negative, #841/#864). Here-strings throughout.
# Hermetic: temp dirs, a real local fixture git repo with its own identity (incl. commit.gpgsign=false
# so ambient config cannot red it), no network, no `$HOME` dependence, no tmux, no controller.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
PROV="$HERE/harness-provenance.sh"
DEPLOY="$HERE/deploy-harness.sh"
MACDEP="$ROOT/scripts/deploy-mac-orchestrator.sh"
SHARDS="$ROOT/scripts/run-bash-shards.sh"
for f in "$PROV" "$DEPLOY" "$MACDEP" "$SHARDS"; do
  [ -s "$f" ] || { echo "❌ missing $f — this suite grades the shipped files, so it cannot run"; exit 2; }
done
command -v git >/dev/null 2>&1 || { echo "❌ git not found — cannot build the fixture repo"; exit 2; }
SHA_CMD="sha256sum"
command -v sha256sum >/dev/null 2>&1 || SHA_CMD="shasum -a 256"
command -v ${SHA_CMD%% *} >/dev/null 2>&1 || { echo "❌ neither sha256sum nor shasum is available"; exit 2; }

PASS=0; FAIL=0; SKIPPED=0
ck() { if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
q()  { grep -q  -- "$1" <<<"${2:-}"; }
qF() { grep -qF -- "$1" <<<"${2:-}"; }
echo "==> harness-provenance self-test ($HERE)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-prov.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
G="git -c user.email=t@t -c user.name=t -c commit.gpgsign=false"

# ── the fixture harness SOURCE: the five anchors deploy-harness.sh demands, plus the record tools ──
SRC="$TMP/src"; mkdir -p "$SRC/gh-rest" "$SRC/gh-limit"
printf '#!/usr/bin/env bash\necho loop\n'    > "$SRC/orch-loop.sh"
printf '#!/usr/bin/env bash\necho claims\n'  > "$SRC/claims.sh"
printf '#!/usr/bin/env python3\nprint(1)\n'  > "$SRC/gh-limit.py"
printf '#!/usr/bin/env bash\necho gh\n'      > "$SRC/gh-rest/gh"
printf '#!/usr/bin/env bash\necho ghlimit\n' > "$SRC/gh-limit/gh"
cp "$PROV" "$SRC/harness-provenance.sh"
chmod +x "$SRC"/*.sh "$SRC/gh-rest/gh" "$SRC/gh-limit/gh"

O="$TMP/O"; mkdir -p "$O"
# A record describes bytes that ARE there — so seed $O from the source first, exactly as a deploy
# would. (The writer REFUSES to record a tree missing a file the source ships — graded immediately
# below — which is why this suite cannot skip the copy.)
cp -R "$SRC"/. "$O"/
rm -f "$O/gh-rest/gh"          # one source file the deploy has not written yet
bash "$PROV" write --o "$O" --src "$SRC" >/dev/null 2>&1; RC=$?
ck "the writer REFUSES to record an INCOMPLETE deploy (exit 1, nothing written)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…and no record was left behind by the refusal" "$([ -e "$O/.harness-provenance" ] && echo 1 || echo 0)"
cp -R "$SRC"/. "$O"/          # now the deploy is complete
bash "$PROV" write --o "$O" --src "$SRC" --commit 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1
ck "a record was written at \$O/.harness-provenance" "$([ -s "$O/.harness-provenance" ] && echo 0 || echo 1)"
REC_TXT="$(cat "$O/.harness-provenance" 2>/dev/null)"
ck "it names the commit the deploy came from" "$(qF "commit=0123456789abcdef0123456789abcdef01234567" "$REC_TXT" && echo 0 || echo 1)"
NFILES="$(sed -n 's/^files=//p' "$O/.harness-provenance" 2>/dev/null | head -1)"
NM="$(sed -n '/^[0-9a-f]\{64\}  /p' "$O/.harness-provenance" 2>/dev/null | wc -l | tr -d ' ')"
ck "its files= count equals its manifest entries ($NM)" "$([ "${NFILES:-x}" = "$NM" ] && [ "$NM" -ge 6 ] && echo 0 || echo 1)"
ck "the manifest covers a NESTED file the source ships (gh-rest/gh)" "$(qF "gh-rest/gh" "$REC_TXT" && echo 0 || echo 1)"
ck "…and NOT the record itself (a record that lists itself can never be verified)" "$(qF "  .harness-provenance" "$REC_TXT" && echo 1 || echo 0)"
SHOW="$(bash "$PROV" show --o "$O" 2>&1)"
ck "show prints the one-line answer (commit + recorded time + file count)" "$(qF "harness commit 0123456789ab" "$SHOW" && echo 0 || echo 1)"

echo
echo "── §1b \$O is NEVER its own source (a self-manifest is a tautology that blesses anything) ──"
bash "$PROV" write --o "$O" --src "$O" >/dev/null 2>&1; RC=$?
ck "refused (78) with \$O as --src" "$([ "$RC" -eq 78 ] && echo 0 || echo 1)"

echo
echo "── §2 check: clean is a MEASURED 0; an edit is named; no record is UNKNOWN, never clean ──"
OUT="$(bash "$PROV" check --o "$O" 2>&1)"; RC=$?
ck "rc is 0 on the tree the record describes" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
# ⛔ BACKDATED first: a one-second mtime resolution puts an edit and its record in the SAME second,
# where `-nt` is false and the honest answer is "cannot order them" — a different arm.
touch -t 202001010000 "$O/.harness-provenance"
printf '#!/usr/bin/env bash\necho PATCHED\n' > "$O/claims.sh"
OUT="$(bash "$PROV" check --o "$O" 2>&1)"; RC=$?
ck "rc is 1 when one file differs from the record" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…and the report NAMES claims.sh" "$(qF "UNCOMMITTED-EDIT   claims.sh" "$OUT" && echo 0 || echo 1)"
ck "…and says which side is newer (edited after the record)" "$(qF "edited AFTER the record" "$OUT" && echo 0 || echo 1)"
OUT="$(bash "$PROV" check --o "$O" --src "$SRC" 2>&1)"; RC=$?
ck "narrowed to a source, that edit is still reported (the deploy WOULD overwrite it)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
rm -f "$O/.harness-provenance"
OUT="$(bash "$PROV" check --o "$O" 2>&1)"; RC=$?
ck "NO record is exit 2 (cannot answer — never a clean result)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "…and says it cannot be answered" "$(qF "CANNOT BE ANSWERED" "$OUT" && echo 0 || echo 1)"

echo
echo "── §2a write() can never describe bytes the SOURCE does not have (the false-provenance shape) ──"
# ⛔ `write` hashes what `$O` HOLDS. Run on a hand-patched box it used to succeed and record the patched
# bytes under the checkout's commit — after which `check` read the patch as "deployed" (alarm silenced)
# and the next deploy overwrote it believing it was its own bytes. Measured: exit 0, then `check --src`
# said clean while `cmp` said the two sides differ. That is the 2026-10-28 incident re-enabled by the
# tool's own remedy, so the refusal is asserted here rather than left to a comment.
O2a="$TMP/o2a"; mkdir -p "$O2a"; cp -R "$SRC"/. "$O2a"/
printf '#!/usr/bin/env bash\necho VANISH-THE-PATCH\n' > "$O2a/claims.sh"     # $O carries foreign bytes
OUT="$(bash "$PROV" write --o "$O2a" --src "$SRC" 2>&1)"; RC=$?
ck "write REFUSES (1) when \$O holds bytes the source does not have" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…names the file and says a record now would be false provenance" \
   "$(qF "DIFFERS from" "$OUT" && qF "false provenance" "$OUT" && echo 0 || echo 1)"
ck "…and wrote NO record" "$([ -e "$O2a/.harness-provenance" ] && echo 1 || echo 0)"
# the same call on matching bytes still works (the refusal is about the bytes, not about write())
bash "$PROV" write --o "$O2a" --src "$SRC" --commit UNKNOWN >/dev/null 2>&1; RC=$?
ck "…and it is the BYTES it refuses, not write() itself" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
cp "$SRC/claims.sh" "$O2a/claims.sh"
bash "$PROV" write --o "$O2a" --src "$SRC" >/dev/null 2>&1; RC=$?
ck "…restoring the source's bytes lets it record (0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"

# ⛔ AN EMPTY `--src` MUST NOT ANSWER "CLEAN". The narrowing drops every record entry when the source
# ships nothing, so the gate compared NOTHING and said 0 — while the edited file sat in $O.
EMPTY="$TMP/empty-src"; mkdir -p "$EMPTY"
OUT="$(bash "$PROV" check --o "$O2a" --src "$EMPTY" 2>&1)"; RC=$?
ck "check --src against an EMPTY source is UNKNOWN (2), never clean" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "…and says it would compare nothing" "$(qF "ships NO files" "$OUT" && echo 0 || echo 1)"

# ⛔ `--skip` IS THE PARTIAL DEPLOY'S WRITE SET. `deploy-mac-orchestrator.sh` PHASE=A never writes
# orch-loop.sh; without the seam an edit to that one file refused a run that would not touch it.
touch -t 202001010000 "$O2a/.harness-provenance"
printf '#!/usr/bin/env bash\necho PHASE-B-OWNED\n' > "$O2a/orch-loop.sh"
OUT="$(bash "$PROV" check --o "$O2a" --src "$SRC" 2>&1)"; RC=$?
ck "an edited orch-loop.sh IS an edit for a full deploy (1)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
OUT="$(bash "$PROV" check --o "$O2a" --src "$SRC" --skip orch-loop.sh 2>&1)"; RC=$?
ck "…and is NOT one for a PHASE=A run, which never writes it (0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"

echo
echo "── §2aa a record survives a source path with TWO SPACES, and 'newer than the record' is not an edit ──"
# ⛔ THE FORMAT'S OWN ROUND TRIP. The reader used to classify a manifest line by "the line contains two
# spaces" — and the deploy writes `source=<checkout path>`, so a checkout named with two consecutive
# spaces became a manifest entry: `check` exited 2 "cannot parse EVERY entry"... forever (re-recording
# reproduced it), and the drift reader invented a MISSING file from a path that never existed. A record
# the writer cannot read back is worse than no record.
ODDROOT="$TMP/odd  repo (two spaces)"; mkdir -p "$ODDROOT/src"; cp -R "$SRC"/. "$ODDROOT/src"/
OO="$TMP/odd-o"; mkdir -p "$OO"; cp -R "$ODDROOT/src"/. "$OO"/
bash "$PROV" write --o "$OO" --src "$ODDROOT/src" >/dev/null 2>&1; RC=$?
ck "a source path with TWO SPACES still records (0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
OUT="$(bash "$PROV" check --o "$OO" 2>&1)"; RC=$?
ck "…and the record reads back (0 — it used to be unparseable forever)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
# ⛔ `PHASE=A` WRITES $O AND NO RECORD. So a routine partial deploy leaves bytes that differ from the
# record with nobody having edited anything; calling that "recover the edit" sends an operator after a
# patch that does not exist.
printf '#!/usr/bin/env bash\necho PENDING-DEPLOY\n' > "$SRC/claims.sh"
cp "$SRC/claims.sh" "$OO/claims.sh"                       # …a "phase A" deploy: bytes land, no record
OUT="$(bash "$PROV" check --o "$OO" --src "$SRC" 2>&1)"; RC=$?
ck "bytes that already equal the SOURCE are PENDING, not an edit (0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and the report names them PENDING" "$(qF "PENDING   claims.sh" "$OUT" && echo 0 || echo 1)"
ck "…and does not call them an UNCOMMITTED-EDIT" "$(qF "UNCOMMITTED-EDIT" "$OUT" && echo 1 || echo 0)"
# ⛔ THE DOCUMENTED CALL IS `check --o $O` (no --src) — README §4.3 gives exactly that command. The
# PENDING classification lives outside the --src narrowing now, using the `source=` field the record
# itself carries, so the documented call reports the same state the same way.
# The record names `source=<the tree it was written from>`, and a real phase-A deploy advances BOTH that
# tree and `$O` — so model that, not a half-state.
cp "$SRC/claims.sh" "$ODDROOT/src/claims.sh"
OUT="$(bash "$PROV" check --o "$OO" 2>&1)"; RC=$?
ck "plain check: bytes equal to the record's own source are PENDING (0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and the plain report says PENDING, not UNCOMMITTED-EDIT" \
   "$(qF "PENDING   claims.sh" "$OUT" && qF "UNCOMMITTED-EDIT" "$OUT" && echo 1 || qF "PENDING   claims.sh" "$OUT" && echo 0 || echo 1)"
# an actual edit (bytes matching NEITHER side) is still an edit
printf '#!/usr/bin/env bash\necho HAND-PATCH\n' > "$OO/claims.sh"
OUT="$(bash "$PROV" check --o "$OO" --src "$SRC" 2>&1)"; RC=$?
ck "…while bytes matching neither side are still an edit (1)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
cp "$SRC/claims.sh" "$OO/claims.sh"

# ⛔ `cmp` EXITS 2 ON AN I/O ERROR, AND THAT IS NOT "DIFFERS". Reporting it as a difference told an
# operator to "land the difference" between two byte-IDENTICAL files.
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$SRC/claims.sh"
  OUT="$(bash "$PROV" write --o "$OO" --src "$SRC" 2>&1)"; RC=$?
  chmod 755 "$SRC/claims.sh"
  ck "an UNREADABLE source file is 'cannot COMPARE', not 'DIFFERS' (rc 1)" \
     "$([ "$RC" -eq 1 ] && qF "cannot COMPARE" "$OUT" && echo 0 || echo 1)"
  ck "…and it does not tell the operator to land a difference that is not there" "$(qF "DIFFERS from" "$OUT" && echo 1 || echo 0)"
else
  SKIPPED=$((SKIPPED + 1))
fi

echo
echo "── §2b a record that cannot describe itself is UNKNOWN, and a MISSING file is not an edit ──"
# `check` IS THE REFUSAL GATE both deploys call, so the permissive branch here is the one that lets a
# hand-patched box through. Two shapes it must refuse, and one it must NOT call a refusal.
O2="$TMP/o2"; mkdir -p "$O2"; cp -R "$SRC"/. "$O2"/
bash "$PROV" write --o "$O2" --src "$SRC" >/dev/null 2>&1
sed 's/^files=.*/files=0/' "$O2/.harness-provenance" > "$TMP/r0" && mv "$TMP/r0" "$O2/.harness-provenance"
OUT="$(bash "$PROV" check --o "$O2" --src "$SRC" 2>&1)"; RC=$?
ck "files=0 is UNKNOWN (2) — never a clean answer to a gate" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "…and says an EMPTY manifest cannot describe any bytes" "$(qF "EMPTY manifest" "$OUT" && echo 0 || echo 1)"
bash "$PROV" write --o "$O2" --src "$SRC" >/dev/null 2>&1
sed 's/^files=.*/files=99/' "$O2/.harness-provenance" > "$TMP/r1" && mv "$TMP/r1" "$O2/.harness-provenance"
OUT="$(bash "$PROV" check --o "$O2" 2>&1)"; RC=$?
ck "a files= count that disagrees with the manifest is UNKNOWN (2)" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "…and names the disagreement rather than trusting the lines it read" "$(qF "manifest line" "$OUT" && echo 0 || echo 1)"
# ⛔ THE OTHER DIRECTION OF THE SAME GATE, and the one that shipped broken: a hand-placed file that the
# INCOMING SOURCE also ships. The `--src` scan used to walk only the RECORD's entries, on the stated
# premise that "the deploy does not delete files" — true, and irrelevant: a deploy destroys a file by
# WRITING one of that name, not by deleting it. Measured before the fix: a hand-placed `foo.sh` in $O,
# a record from a source that never shipped `foo.sh`, a new source that DOES ship it → `check --src`
# said CLEAN (0) and the deploy replaced the hand-placed bytes, printing nothing. That is the
# 2026-10-28 incident one file name over.
O2b="$TMP/o2b"; mkdir -p "$O2b"; cp -R "$SRC"/. "$O2b"/
OLDSRC="$TMP/old-src"; mkdir -p "$OLDSRC"; cp -R "$SRC"/. "$OLDSRC/"; rm -f "$OLDSRC/extra.sh"
printf '#!/usr/bin/env bash\necho v1\n' > "$O2b/extra.sh"          # hand-placed; the OLD source lacks it
bash "$PROV" write --o "$O2b" --src "$OLDSRC" >/dev/null 2>&1         # the record never saw extra.sh
printf '#!/usr/bin/env bash\necho FROM-THE-REF\n' > "$SRC/extra.sh"  # the NEW source ships that name
OUT="$(bash "$PROV" check --o "$O2b" 2>&1)"; RC=$?
ck "a hand-placed file is an edit for a plain check (1)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
OUT="$(bash "$PROV" check --o "$O2b" --src "$SRC" 2>&1)"; RC=$?
ck "…and STILL one when the source ships that name (the deploy would overwrite it)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "…named, with the reason it matters" "$(qF "UNCOMMITTED-EDIT   extra.sh" "$OUT" && echo 0 || echo 1)"
ck "…and says this deploy would OVERWRITE it" "$(qF "would OVERWRITE it" "$OUT" && echo 0 || echo 1)"
BEFORE_X="$($SHA_CMD "$O2b/extra.sh" | awk '{print $1}')"
PATH="/tmp/no-tts:$PATH" bash "$DEPLOY" --src "$SRC" --o "$O2b" --no-notify >/dev/null 2>&1; RC=$?
AFTER_X="$($SHA_CMD "$O2b/extra.sh" | awk '{print $1}')"
ck "the deploy REFUSES (78) rather than replace it" "$([ "$RC" -eq 78 ] && echo 0 || echo 1)"
ck "…and the hand-placed bytes are untouched" "$([ "$BEFORE_X" = "$AFTER_X" ] && echo 0 || echo 1)"
rm -f "$SRC/extra.sh"                                                # leave the shared fixture as found

# ⛔ A MISSING file is one the deploy CREATES. Counting it as an edit made the deploy print "carries
# UNCOMMITTED EDITS … copy them aside" about a file that is not there, and made --accept-discard the
# only way to repair a half-made deploy.
bash "$PROV" write --o "$O2" --src "$SRC" >/dev/null 2>&1
rm -f "$O2/gh-rest/gh"
OUT="$(bash "$PROV" check --o "$O2" --src "$SRC" 2>&1)"; RC=$?
ck "a MISSING file is REPORTED by name" "$(qF "MISSING   gh-rest/gh" "$OUT" && echo 0 || echo 1)"
ck "…and is NOT an edit (the deploy would create it: rc 0, not 1)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and the report says it is not a refusal" "$(qF "not a refusal" "$OUT" && echo 0 || echo 1)"

echo
echo "── §2d a deploy from a DIRTY checkout records the fact (the commit it names is not these bytes) ──"
# ⛔ THE LEGACY STAMP CARRIED THIS (`agentInfraDirty`) AND THE RECORD DID NOT — so the BETTER record masked
# the only dirtiness signal the codebase had: a deploy staged from a checkout with uncommitted changes
# recorded `commit=<HEAD>` for bytes HEAD does not contain, and the box's one-line answer named a commit
# it was not running.
DREPO="$TMP/dirty-repo"; mkdir -p "$DREPO/scripts/orchestrator-harness"
cp -R "$SRC"/. "$DREPO/scripts/orchestrator-harness"/
( cd "$DREPO" && $G init -q -b main . && $G add -A && $G commit -qm base ) >/dev/null 2>&1
DO="$TMP/dirty-o"; mkdir -p "$DO"
printf '#!/usr/bin/env bash\necho WORK-IN-PROGRESS\n' > "$DREPO/scripts/orchestrator-harness/claims.sh"
PATH="/tmp/no-tts:$PATH" bash "$DEPLOY" --src "$DREPO/scripts/orchestrator-harness" --o "$DO" --no-notify >/dev/null 2>&1; RC=$?
ck "a deploy from a DIRTY checkout still completes and records (0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and the record says sourceDirty=true instead of implying the commit owns these bytes" \
   "$(qF "sourceDirty=true" "$(cat "$DO/.harness-provenance" 2>/dev/null)" && echo 0 || echo 1)"
OUT="$(bash "$PROV" show --o "$DO" 2>&1)"
ck "…and show says the source was DIRTY beside the commit" "$(qF "SOURCE WAS DIRTY" "$OUT" && echo 0 || echo 1)"
ck "the dirty-source warning is printed, not silent" \
   "$(qF "UNCOMMITTED changes" "$(PATH="/tmp/no-tts:$PATH" bash "$DEPLOY" --src "$DREPO/scripts/orchestrator-harness" --o "$DO" --no-notify --accept-discard 2>&1)" && echo 0 || echo 1)"

echo
echo "── §3 THE MEASURED INCIDENT: a deploy onto a dirty \$O REFUSES and names what it would discard ──"
# 1) a clean deploy, so the box has an honest record of its own bytes
PATH="/tmp/no-tts:$PATH" bash "$DEPLOY" --src "$SRC" --o "$O" --no-notify >/dev/null 2>&1; RC=$?
ck "the baseline deploy verifies (0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and it RECORDED the deploy's provenance (the box is attributable)" "$([ -s "$O/.harness-provenance" ] && echo 0 || echo 1)"
# 2) the hand patch — the shape that was silently reverted on 2026-10-28
touch -t 202001010000 "$O/.harness-provenance"
printf '#!/usr/bin/env bash\necho hand-patched\n' > "$O/claims.sh"
BEFORE="$($SHA_CMD "$O/claims.sh" | awk '{print $1}')"
OUT="$(PATH="/tmp/no-tts:$PATH" bash "$DEPLOY" --src "$SRC" --o "$O" --no-notify 2>&1)"; RC=$?
ck "the deploy REFUSES (78) before touching the target" "$([ "$RC" -eq 78 ] && echo 0 || echo 1)"
ck "…and names the file it would have discarded" "$(qF "claims.sh" "$OUT" && echo 0 || echo 1)"
ck "…and says what to do instead of discarding it" "$(qF "--accept-discard" "$OUT" && echo 0 || echo 1)"
AFTER="$($SHA_CMD "$O/claims.sh" | awk '{print $1}')"
ck "…and the patched bytes are STILL THERE (a refusal copies nothing)" "$([ "$BEFORE" = "$AFTER" ] && echo 0 || echo 1)"
ck "…and the rest of the tree was not copied either (orch-loop.sh untouched)" \
   "$(qF "echo loop" "$(cat "$O/orch-loop.sh")" && echo 0 || echo 1)"
# 3) the deliberate override: the operator says discard, and the record then describes the new bytes
OUT="$(PATH="/tmp/no-tts:$PATH" bash "$DEPLOY" --src "$SRC" --o "$O" --no-notify --accept-discard 2>&1)"; RC=$?
ck "--accept-discard proceeds (0) and the deploy still verifies" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
OUT="$(bash "$PROV" check --o "$O" 2>&1)"; RC=$?
ck "…and the box's own record now describes the bytes it holds (check is 0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"

# ⛔ THE DURABLE RECORD, not just this run's output: a deploy that could not tell what it would discard
# must leave that in the ledger the NEXT operator reads. (Measured defect: the row was appended before
# `detail` was reset, so the ledger said VERIFIED with no trace of the unknown at all.)
O3="$TMP/o3"; mkdir -p "$O3"
PATH="/tmp/no-tts:$PATH" bash "$DEPLOY" --src "$SRC" --o "$O3" --no-notify >/dev/null 2>&1; RC=$?
ck "a deploy onto an UNRECORDED \$O still completes (it cannot know, and says so)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and the DURABLE ledger carries the DISCARD-UNKNOWN row" \
   "$(qF "DISCARD-UNKNOWN" "$(cat "$O3/.deploy-ledger.tsv" 2>/dev/null)" && echo 0 || echo 1)"

# ⛔ A CHECKOUT PATH WITH A SPACE. `git worktree list --porcelain` returns whatever the user named it,
# and a JOINED flag string passed unquoted split into `--repo /tmp/repo` + a stray `with` + `space`,
# which the writer refuses as an unknown argument — measured: exit 78, NO record written, and the deploy
# then reports PROVENANCE-FAILED. The array is the fix; this arm is what keeps it an array.
SP="$TMP/space dir/src"; mkdir -p "$SP"; cp -R "$SRC"/. "$SP"/
( cd "$SP" && $G init -q -b main . && $G add -A && $G commit -qm space ) >/dev/null 2>&1
O4="$TMP/o4"; mkdir -p "$O4"
PATH="/tmp/no-tts:$PATH" bash "$DEPLOY" --src "$SP" --o "$O4" --no-notify >/dev/null 2>&1; RC=$?
ck "a deploy from a checkout path WITH A SPACE still verifies (0)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and the record was written (the flags survived the space)" "$([ -s "$O4/.harness-provenance" ] && echo 0 || echo 1)"
ck "…and it names a resolved commit, not UNKNOWN" \
   "$(qF "commit=UNKNOWN" "$(cat "$O4/.harness-provenance" 2>/dev/null)" && echo 1 || echo 0)"

echo
echo "── §4 the macOS deploy path: DRY RUN writes NOTHING, and it REFUSES a dirty \$O (never run live) ──"
# ⛔ THE REAL SCRIPT IS NEVER RUN FOR REAL HERE: it would overwrite THIS box's live $O, which is the
# incident. `--dry-run` (and a fixture $O/$AI_MAIN) exercises the plan, the refusal and the provenance
# write path without touching anything.
R="$TMP/repo"; mkdir -p "$R/scripts/orchestrator-harness"
cp "$SRC/orch-loop.sh" "$SRC/claims.sh" "$SRC/gh-limit.py" "$SRC/harness-provenance.sh" "$R/scripts/orchestrator-harness/"
mkdir -p "$R/scripts/orchestrator-harness/gh-rest" "$R/scripts/orchestrator-harness/gh-limit"
cp "$SRC/gh-rest/gh" "$R/scripts/orchestrator-harness/gh-rest/gh"
cp "$SRC/gh-limit/gh" "$R/scripts/orchestrator-harness/gh-limit/gh"
( cd "$R" && $G init -q -b main . && $G add -A && $G commit -qm fixture ) >/dev/null 2>&1
ck "the fixture repo has a commit" "$([ -n "$(git -C "$R" rev-parse HEAD 2>/dev/null)" ] && echo 0 || echo 1)"
MO="$TMP/maco"; mkdir -p "$MO"
BEFORE_LS="$(ls -1 "$MO" | wc -l | tr -d ' ')"
OUT="$(AI_MAIN="$R" SRC_REF=main O="$MO" PHASE=A STAGE="$TMP/stage1" bash "$MACDEP" --dry-run 2>&1)"; RC=$?
ck "--dry-run exits 0" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…says it is a DRY RUN and names what it would overwrite" "$(qF "DRY RUN" "$OUT" && qF "overwrite" "$OUT" && echo 0 || echo 1)"
ck "…and wrote NOTHING into \$O (no copy, no record)" "$([ "$(ls -1 "$MO" | wc -l | tr -d ' ')" = "$BEFORE_LS" ] && echo 0 || echo 1)"
ck "…and no record exists there" "$([ -e "$MO/.harness-provenance" ] && echo 1 || echo 0)"
# a dirty $O: the same refusal as deploy-harness.sh, on the macOS path
cp -R "$R/scripts/orchestrator-harness"/. "$MO"/
bash "$PROV" write --o "$MO" --src "$R/scripts/orchestrator-harness" --commit "$(git -C "$R" rev-parse HEAD)" >/dev/null 2>&1
touch -t 202001010000 "$MO/.harness-provenance"
printf '#!/usr/bin/env bash\necho hand-patched\n' > "$MO/claims.sh"
OUT="$(AI_MAIN="$R" SRC_REF=main O="$MO" PHASE=A STAGE="$TMP/stage2" bash "$MACDEP" --dry-run 2>&1)"; RC=$?
ck "a dirty \$O makes even the DRY RUN refuse (78)" "$([ "$RC" -eq 78 ] && echo 0 || echo 1)"
ck "…naming the file it would discard" "$(qF "claims.sh" "$OUT" && echo 0 || echo 1)"
ck "…and pointing at the deliberate override" "$(qF "--accept-discard" "$OUT" && echo 0 || echo 1)"
ck "…and the patched bytes survive the refusal" "$(qF "hand-patched" "$(cat "$MO/claims.sh")" && echo 0 || echo 1)"
ck "…and the PLAN is printed WITH the refusal (it is what --accept-discard would destroy)" \
   "$(qF "overwrite    claims.sh" "$OUT" && echo 0 || echo 1)"
# ⛔ A REF THAT PREDATES THE CHECKER. `DISC_RC` starts at 0 in the old code and is only reassigned when
# the staged harness ships the checker, so this arm read as a CLEAN deploy over a box nobody inspected —
# the 2026-10-28 silence, on the ref most likely to produce it.
R2="$TMP/repo-old"; mkdir -p "$R2/scripts/orchestrator-harness"
cp "$SRC/orch-loop.sh" "$SRC/claims.sh" "$R2/scripts/orchestrator-harness/"
( cd "$R2" && $G init -q -b main . && $G add -A && $G commit -qm old ) >/dev/null 2>&1
OUT="$(AI_MAIN="$R2" SRC_REF=main O="$MO" PHASE=A STAGE="$TMP/stage3" bash "$MACDEP" --dry-run 2>&1)"; RC=$?
ck "a ref with NO checker: the dry run says it CANNOT TELL what it would discard" "$(qF "CANNOT" "$OUT" && echo 0 || echo 1)"
ck "…and names the actual reason (the staged harness ships no harness-provenance.sh)" \
   "$(qF "ships no harness-provenance.sh" "$OUT" && echo 0 || echo 1)"
ck "…and does not claim the box is clean" "$(qF "nothing to discard" "$OUT" && echo 1 || echo 0)"
# ⛔ PHASE=A IS ITS OWN WRITE SET. A run that leaves `orch-loop.sh` to phase B must not refuse over it —
# and must not offer `--accept-discard` for a file it never writes.
M2="$TMP/macA"; cp -R "$MO"/. "$M2"/                                         # carries the dirty claims.sh
cp "$SRC/claims.sh" "$M2/claims.sh"                                          # …so restore it: the ONLY
bash "$PROV" write --o "$M2" --src "$R/scripts/orchestrator-harness" >/dev/null 2>&1 || true   # edit left
touch -t 202001010000 "$M2/.harness-provenance" 2>/dev/null || true          # is orch-loop.sh, below
printf '#!/usr/bin/env bash\necho PHASE-B-OWNED\n' > "$M2/orch-loop.sh"
OUT="$(AI_MAIN="$R" SRC_REF=main O="$M2" PHASE=A STAGE="$TMP/stage4" bash "$MACDEP" --dry-run 2>&1)"; RC=$?
ck "PHASE=A does NOT refuse over orch-loop.sh (phase B owns it)" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "…and plans no overwrite for it" "$(qF "overwrite    orch-loop.sh" "$OUT" && echo 1 || echo 0)"
OUT="$(AI_MAIN="$R" SRC_REF=main O="$M2" PHASE=AB STAGE="$TMP/stage5" bash "$MACDEP" --dry-run 2>&1)"; RC=$?
ck "a full PHASE=AB run DOES refuse over the same file (78)" "$([ "$RC" -eq 78 ] && echo 0 || echo 1)"

# ⛔ "$O does not exist yet " + "this run creates it" must be TRUE for a real run, and a DRY RUN must not
# claim it. The claim was printed with no `mkdir -p "$O"` anywhere in the script.
M3="$TMP/macfresh/O-missing"
OUT="$(AI_MAIN="$R" SRC_REF=main O="$M3" PHASE=A STAGE="$TMP/stage6" bash "$MACDEP" --dry-run 2>&1)"; RC=$?
ck "a dry run against a MISSING \$O says it writes nothing" "$(qF "a DRY RUN writes nothing" "$OUT" && echo 0 || echo 1)"
ck "…and a PHASE=A dry run does not promise a record or a phase B it will not perform" \
   "$(qF "the record that would be written" "$OUT" && echo 1 || qF "phase B would swap" "$OUT" && echo 1 || echo 0)"
ck "…and says phase A leaves orch-loop.sh alone and writes NO record" \
   "$(qF "NO record is written" "$OUT" && echo 0 || echo 1)"
ck "…and creates nothing" "$([ -e "$M3" ] && echo 1 || echo 0)"
OUT="$(AI_MAIN="$R" SRC_REF=main O="$M3" PHASE=A STAGE="$TMP/stage7" bash "$MACDEP" 2>&1)"; RC=$?
ck "a real PHASE=A run CREATES the missing \$O (it used to die on its own cp)" "$([ -d "$M3" ] && echo 0 || echo 1)"
ck "…and it lands claims.sh there" "$([ -f "$M3/claims.sh" ] && echo 0 || echo 1)"
ck "…and writes NO record (a phase-A tree is not a complete deploy)" "$([ -e "$M3/.harness-provenance" ] && echo 1 || echo 0)"

echo
echo "── §5 this suite is REGISTERED as a shard (the ONE list both CI lanes run) ──"
# ⛔ A BACKTICK INSIDE A DOUBLE-QUOTED ASSERTION DESCRIPTION IS A COMMAND SUBSTITUTION (VGATE round 1,
# measured): `ck "…and `show` says …"` RAN `show` on every green run and printed
# `show: command not found` to stderr while the suite still exited 0 — a green run that emits a bare
# command error teaches whoever reads CI to ignore its stderr, which is where a real failure shows up.
# (This is the same trap the commit-message rule forbids; here it is graded rather than prohibited.)
BTICK=$(grep -nE '^[[:space:]]*ck "[^"]*`' "${BASH_SOURCE[0]}" 2>/dev/null || true)
ck "no assertion description contains a backtick (it would run as a command)" \
   "$([ -z "$BTICK" ] && echo 0 || echo 1)"
[ -z "$BTICK" ] || printf '      %s\n' "$BTICK"
ck "run-bash-shards.sh carries this suite as a run_shard line" \
   "$(q 'run_shard scripts/orchestrator-harness/harness-provenance.test.sh' "$(cat "$SHARDS")" && echo 0 || echo 1)"

echo
if [ "$SKIPPED" -gt 0 ]; then printf 'SKIPPED: %d sub-case(s) NOT executed on this host\n' "$SKIPPED"; fi
printf 'harness-provenance self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
