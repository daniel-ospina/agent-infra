#!/usr/bin/env bash
# check-deployed-drift.test.sh — DEPLOYMENT PROVENANCE, proven by its EFFECT: a one-byte change in
# the deployed copy flips the verdict, and "cannot verify" is never a pass.
#
# ── WHY THIS FILE EXISTS (agent-infra#2700) ──────────────────────────────────────────────────────
# `check-deployed-drift.sh` answers the ONE question a self-healing harness rests on: *are the bytes
# this box executes the bytes we reviewed?* It had no suite of its own — only its `--surface` half was
# exercised, from `scripts/harness-cohesion.test.sh`. Its IDENTITY / RELATION / BYTES halves — the
# three that decide MATCH — were graded by nothing.
#
# That is the epic's failure class exactly: a capability that is deployed, scheduled, printed, and
# inert. And the two assertions this file refuses to accept are the epic's two named non-assertions:
#
#   ⛔ "the file exists"  — every box passes that (all four cells carry the scripts).
#   ⛔ "the unit is active" — measured on cell-4, 2026-10-24: `systemctl is-active
#      eldato-orchestrator` printed `active` while the controller it supervises was a FOREIGN pid it
#      was merely waiting for, running an OLDER snapshot than the pin. An active unit is a fact about
#      a supervisor, never about the bytes.
#
# So the assertions below are about the VERDICT and the exit code, driven end to end through the
# shipped `check-deployed-drift.sh` against a REAL local git repo (no network, `--no-fetch`):
#
#   0 OK       the deployed copy IS the ref: same commit, same payload hash, same blobs
#   1 DRIFT    it differs — and the differing FILE is named
#   2 UNKNOWN  it cannot be checked — and that is never a pass
#
# ── THE NON-VACUITY IS STRUCTURAL, NOT A CLAIM ──────────────────────────────────────────────────
# §2 and §3 use the SAME fixture and differ by ONE BYTE of one deployed file; they must produce
# OPPOSITE verdicts. A check that cannot see a one-byte change cannot report drift at all, so this
# pair cannot pass vacuously. §6 then adds the second half of the same argument for the exit code:
# an unreadable deployed file must be UNKNOWN (2), never a silent OK.
#
# ⛔ NO `printf … | grep -q …` (SIGPIPE false negative, agent-infra #841/#864 — enforced by
# scripts/check-no-sigpipe-grep.sh). Here-strings throughout.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRIFT="$HERE/check-deployed-drift.sh"
[ -s "$DRIFT" ] || { echo "❌ missing $DRIFT — this suite grades the shipped file, so it cannot run"; exit 2; }
command -v git >/dev/null 2>&1 || { echo "❌ git not found — cannot build the fixture repo"; exit 2; }

PASS=0; FAIL=0
ck() { if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1)); else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi; }
q() { grep -q -- "$1" <<<"${2:-}"; }
echo "==> check-deployed-drift self-test ($HERE)"

TMP="$(mktemp -d "${TMPDIR:-/tmp}/deployed-drift.XXXXXX")"; trap 'rm -rf "$TMP"' EXIT
REPO="$TMP/repo"; O="$TMP/O"
# A fixture repo whose harness dir ships two scripts. Its own user identity, so no ambient git config
# can decide the branch name or the author (the class #2581 fixed elsewhere).
git init -q -b main "$REPO" >/dev/null 2>&1 || { echo "❌ git init failed"; exit 2; }
mkdir -p "$REPO/scripts/orchestrator-harness"
printf '#!/usr/bin/env bash\necho one\n' > "$REPO/scripts/orchestrator-harness/a.sh"
printf '#!/usr/bin/env bash\necho two\n' > "$REPO/scripts/orchestrator-harness/b.sh"
( cd "$REPO" && git -c user.email=t@t -c user.name=t add -A \
  && git -c user.email=t@t -c user.name=t commit -q -m fixture ) >/dev/null 2>&1
HEAD1="$(git -C "$REPO" rev-parse HEAD)"
ck "fixture repo has a commit" "$([ -n "$HEAD1" ] && echo 0 || echo 1)"

# The deployed copy, byte-identical to the ref's harness dir.
deploy() { # deploy -> refreshes $O from the ref and writes a truthful stamp
  rm -rf "$O"; mkdir -p "$O"
  cp "$REPO/scripts/orchestrator-harness/a.sh" "$REPO/scripts/orchestrator-harness/b.sh" "$O/" || return 1
  local payload
  payload="$( ( cd "$O" && for f in *.sh; do sha256sum "$f"; done ) | sha256sum | awk '{print $1}' )"
  printf '{\n "commit": "%s",\n "payloadSha256": "%s",\n "agentInfraDirty": false\n}\n' \
    "$HEAD1" "$payload" > "$O/.agent-infra-stamp.json"
}
run() { OUT="$(bash "$DRIFT" --o "$O" --repo "$REPO" --ref main --rel scripts/orchestrator-harness --no-fetch "$@" 2>&1)"; RC=$?; }

deploy || { echo "❌ could not deploy the fixture copy"; exit 2; }

echo
echo "── §1 MATCH: the deployed copy IS the ref (rc 0) ──"
run
ck "rc is 0" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
ck "the verdict says OK and names the deployed dir" "$(q 'OK: deployed' "$OUT" && echo 0 || echo 1)"

echo
echo "── §2 DRIFT, one byte: a single edited byte in the deployed copy is DRIFT (rc 1) ──"
printf '#!/usr/bin/env bash\necho ONE\n' > "$O/a.sh"     # one word, one byte case — the whole delta
run
ck "rc is 1 (we compared, and it differs)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "the differing FILE is named, not just a count" "$(q 'a.sh' "$OUT" && echo 0 || echo 1)"
ck "…and it is NOT reported as OK (a drift must never read as a match)" "$(q 'OK: deployed' "$OUT" && echo 1 || echo 0)"

echo
echo "── §3 the SAME fixture with the original bytes is OK again (the check is not stuck red) ──"
deploy
run
ck "rc is 0 again" "$([ "$RC" -eq 0 ] && echo 0 || echo 1)"
# ⛔ §2 + §3 are the non-vacuity pair: identical fixture, ONE byte apart, opposite verdicts.

echo
echo "── §4 RELATION: the record names an older commit than the ref (rc 1, never OK) ──"
printf '#!/usr/bin/env bash\necho three\n' > "$REPO/scripts/orchestrator-harness/b.sh"
( cd "$REPO" && git -c user.email=t@t -c user.name=t add -A \
  && git -c user.email=t@t -c user.name=t commit -q -m fixture2 ) >/dev/null 2>&1
run   # $O still carries HEAD1's bytes and HEAD1's stamp; the ref has moved on
ck "rc is 1 (behind is drift)" "$([ "$RC" -eq 1 ] && echo 0 || echo 1)"
ck "the verdict names being behind, with both revisions" "$(q 'BEHIND' "$OUT" && echo 0 || echo 1)"

echo
echo "── §5 no harness record at all: UNKNOWN (2) — cannot verify is NEVER a pass ──"
rm -f "$O/.agent-infra-stamp.json"
run
ck "rc is 2" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "the verdict says UNKNOWN and names the missing record" \
   "$(q 'UNKNOWN' "$OUT" && q 'no harness record' "$OUT" && echo 0 || echo 1)"

echo
echo "── §6 a record that names no commit is UNKNOWN (2), not \"probably fine\" ──"
deploy; printf '{\n "commit": "UNKNOWN",\n "payloadSha256": "deadbeef",\n "agentInfraDirty": false\n}\n' > "$O/.agent-infra-stamp.json"
run
ck "rc is 2" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "the verdict says the record names no harness commit" "$(q 'names no harness commit' "$OUT" && echo 0 || echo 1)"

echo
echo "── §7 an UNREADABLE deployed file is UNKNOWN (2) — never a partial digest read as OK ──"
deploy; chmod 000 "$O/b.sh"
run
chmod 644 "$O/b.sh" 2>/dev/null || true
ck "rc is 2" "$([ "$RC" -eq 2 ] && echo 0 || echo 1)"
ck "the verdict says it could not hash the deployed copy" "$(q 'could not hash the deployed copy' "$OUT" && echo 0 || echo 1)"

echo
printf 'check-deployed-drift self-test: %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
