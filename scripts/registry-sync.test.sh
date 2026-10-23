#!/usr/bin/env bash
# registry-sync.test.sh — self-check for scripts/registry-sync.sh (agent-infra#2374).
#
# Run: bash scripts/registry-sync.test.sh
#
# HERMETIC: a local BARE repo IS the shared origin, and two throwaway directories ARE two boxes'
# registries. No network, no gh, no real ~/.pi/agent/reviews — the fleet's actual failure mode
# ("box B cannot see a record box A minted") is reproduced with real pushes and real fetches.
#
# Coverage (the issue's own acceptance list):
#   §1  a record pushed from box 1 lands on the shared store
#   §2  ⭐ THE REGRESSION: a record that exists ONLY on the peer becomes visible to a box that
#       never minted it — the whole point of #2374 (before this script there was no path at all)
#   §3  a NEWER record wins on pull
#   §4  an OLDER record is refused on BOTH verbs — a stale record can never move a fresh one,
#       in either direction
#   §5  equal `reviewed_at`, different content → CONFLICT, exit 3, and the local file is untouched
#   §6  two repos' legacy `<pr>.json` files are never collapsed: a repo-less legacy record is not
#       replicated and is counted `unkeyed`; a legacy record WITH a repo is keyed by that repo
#   §7  idempotence — a second `union` writes nothing, pushes nothing, and the registry digest is
#       unchanged (asserted by hash, per the issue)
#   §8  `status` names the records the peer has and this box does not
#   §9  fail-closed — an unreadable remote is UNKNOWN, never "empty, therefore converged"
#   §10 nothing was deleted, in any direction, by any run above
#   §18 the STORE is the truth: a ref deleted out-of-band is RE-PUBLISHED (a stale local cache
#       must never answer `same`) and `status` counts what the store holds
#   §19 a peer record this box's rail cannot USE (no 40-hex head_sha / not strict JSON) never
#       replaces a usable local one, and is exit 4 — not "converged"
#   §20 a store whose ONLY record is unusable is exit 4 (de-vacuumed: a store of its own)
#   §21 a PARALLEL carry (same head, same stamp, different carried_from) is not a conflict
#   §22 a legacy <pr>.json whose own `pr` field denies its filename is never published
#   §23 `status` counts the STORE's records, not this box's cache
#   §24 every network op is BOUNDED and cannot block on an invisible prompt

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SYNC="$SCRIPT_DIR/registry-sync.sh"

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL + 1)); echo "  ❌ $1"; }
assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3 (got: '$1', want: '$2')"; fi; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2; got: $1)"; fi; }
assert_absent() { if [ -e "$2" ]; then bad "$3 (unexpectedly exists: $2)"; else ok "$3"; fi; }
ref_of() { git -C "$1" rev-parse --verify --quiet "refs/reviews/$2" || true; }

T="$(mktemp -d "${TMPDIR:-/tmp}/registry-sync-test.XXXXXX")"
SUMMARY_PRINTED=0
cleanup() {
  rc=$?
  rm -rf "$T" 2>/dev/null || :
  if [ "$SUMMARY_PRINTED" -eq 0 ]; then
    echo "FAILED: the harness aborted before printing its summary (rc=$rc)" >&2
    exit 1
  fi
  exit "$rc"
}
trap cleanup EXIT

if [ ! -f "$SYNC" ]; then
  echo "❌ scripts/registry-sync.sh is missing — nothing to test (this is the PRE-FIX state: no sync path exists at all)" >&2
  SUMMARY_PRINTED=1
  exit 1
fi

# ── fixtures ─────────────────────────────────────────────────────────────────────────────
ORIGIN="$T/origin.git"
STORE="$T/store"
git init -q --bare "$ORIGIN"
git -C "$T" init -q store 2>/dev/null || { mkdir -p "$STORE"; git -C "$STORE" init -q; }
git -C "$STORE" remote add origin "$ORIGIN" 2>/dev/null || git -C "$STORE" remote set-url origin "$ORIGIN"
git -C "$STORE" config user.email sync@test.invalid
git -C "$STORE" config user.name  sync-test
git -C "$STORE" commit -q --allow-empty -m seed
git -C "$STORE" push -q origin HEAD:refs/heads/main

BOX1="$T/box1"; BOX2="$T/box2"
mkdir -p "$BOX1" "$BOX2"

# mint <dir> <key> <reviewed_at> <head_sha> [repo] [pr]
# The field ORDER is record-review.sh's own printf order, so a record produced here is
# byte-comparable with a real one.
mint() {
  local dir="$1" key="$2" at="$3" head="$4" repo="${5:-daniel-ospina/agent-infra}" pr="${6:-2374}"
  printf '{"pr":%d,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"%s","reviewed_at":"%s"}\n' \
    "$pr" "$head" "$repo" "$at" > "$dir/$key.json"
}
mint_legacy() { # <dir> <pr> <reviewed_at> <head>  — no repo field at all
  printf '{"pr":%s,"head_sha":"%s","verdict":"clean","reviewed_at":"%s"}\n' "$2" "$3" "$4" > "$1/$2.json"
}
mint_legacy_repo() { # <dir> <pr> <reviewed_at> <head> <repo>
  printf '{"pr":%s,"head_sha":"%s","verdict":"clean","repo":"%s","reviewed_at":"%s"}\n' \
    "$2" "$4" "$5" "$3" > "$1/$2.json"
}

rsx() { local repo="$1" dir="$2"; shift 2; bash "$SYNC" "$@" --repo "$repo" --dir "$dir" --remote origin --timeout 30 2>&1; }
rs()  { local dir="$1"; shift; rsx "$STORE" "$dir" "$@"; }
# `--remote origin` is pinned by the wrapper ON PURPOSE: the script honours $REGISTRY_SYNC_REMOTE,
# so a fleet/dev shell exporting it would point this "local bare origin" suite at a real remote.
# `--dir` and `--timeout` are pinned for the same reason.
RS_LAST=""; RS_RC=0
rs_rc() { local dir="$1"; shift; RS_LAST="$(rs "$dir" "$@" 2>&1)"; RS_RC=$?; }

HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
HEAD_C="cccccccccccccccccccccccccccccccccccccccc"
KEY="daniel-ospina-agent-infra-2374"

digest() { # the registry's content digest — the idempotence assertion of #2374 item 3
  ( cd "$1" 2>/dev/null || exit 0
    for f in *.json; do [ -e "$f" ] || continue; printf '%s ' "$f"; command cat "$f"; done ) \
    | if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi | awk '{print $1}'
}

echo "── §1 push publishes a record to the shared store"
mint "$BOX1" "$KEY" "2026-10-20T10:00:00Z" "$HEAD_A"
OUT="$(rs "$BOX1" push)"
assert_contains "$OUT" "pushed $KEY" "§1 push reports the ref it published"
if [ -n "$(ref_of "$STORE" "$KEY")" ]; then ok "§1 refs/reviews/$KEY exists on the shared store"; else bad "§1 refs/reviews/$KEY missing after push"; fi
if [ -n "$(git -C "$STORE" ls-remote --refs origin "refs/reviews/$KEY")" ]; then
  ok "§1 the ref is on the REMOTE (another box can fetch it)"
else
  bad "§1 the ref never reached the remote"
fi

echo "── §2 ⭐ a record minted on ANOTHER box becomes visible here"
assert_absent "$BOX2" "$BOX2/$KEY.json" "§2 precondition: box 2 has never seen this record"
OUT="$(rs "$BOX2" pull)"
assert_contains "$OUT" "pulled $KEY" "§2 pull reports materialising the peer's record"
if [ -f "$BOX2/$KEY.json" ] && cmp -s "$BOX1/$KEY.json" "$BOX2/$KEY.json"; then
  ok "§2 box 2 now holds box 1's record BYTE-IDENTICALLY (the #2374 failure, closed)"
else
  bad "§2 box 2 still cannot see the record box 1 minted"
fi

echo "── §3 a NEWER record wins on pull"
mint "$BOX1" "$KEY" "2026-10-21T10:00:00Z" "$HEAD_B"
rs "$BOX1" push >/dev/null
assert_contains "$(rs "$BOX2" pull)" "pulled $KEY" "§3 a newer record is pulled over an older local one"
assert_contains "$(command cat "$BOX2/$KEY.json")" "$HEAD_B" "§3 box 2 holds the NEWER head"

echo "── §4 an OLDER record is refused on both verbs"
# box 2 becomes the newest, and publishes it
mint "$BOX2" "$KEY" "2026-10-22T10:00:00Z" "$HEAD_C"
rs "$BOX2" push >/dev/null
# (a) PULL must not move a NEWER local backwards
mint "$BOX1" "$KEY" "2026-10-23T10:00:00Z" "$HEAD_A"        # local is newest, not yet pushed
OUT="$(rs "$BOX1" pull)"
assert_contains "$OUT" "keep $KEY" "§4 pull keeps a NEWER local record and names it"
assert_contains "$(command cat "$BOX1/$KEY.json")" "$HEAD_A" "§4 ...and the newer local bytes survive the pull"
# (b) PUSH must not move a NEWER remote backwards
rs "$BOX1" push >/dev/null                                   # remote now 10-23
mint "$BOX1" "$KEY" "2026-10-22T10:00:00Z" "$HEAD_B"         # a stale local record appears
OUT="$(rs "$BOX1" push)"
assert_contains "$OUT" "peer is NEWER" "§4 push refuses to overwrite a NEWER remote record"
assert_contains "$(git -C "$STORE" show "refs/reviews/$KEY:record.json")" "$HEAD_A" \
  "§4 the shared store still holds the NEWEST record after the stale push attempt"

echo "── §5 equal reviewed_at + different content → CONFLICT, exit 3, local untouched"
rs "$BOX1" push >/dev/null 2>&1 || true
mint "$BOX1" "$KEY" "2026-10-23T10:00:00Z" "$HEAD_C"         # same timestamp as the remote, other head
BEFORE="$(digest "$BOX1")"
rs_rc "$BOX1" pull
assert_eq "$RS_RC" "3" "§5 pull exits 3 on divergence"
assert_contains "$RS_LAST" "CONFLICT $KEY" "§5 the divergence is REPORTED, naming the key"
assert_eq "$(digest "$BOX1")" "$BEFORE" "§5 neither side was written (rule 4: report, never overwrite)"
rs_rc "$BOX1" push
assert_eq "$RS_RC" "3" "§5 push diverges too (same timestamp, still different bytes)"
assert_contains "$(git -C "$STORE" show "refs/reviews/$KEY:record.json")" "$HEAD_A" \
  "§5 ...and the divergence did not reach the shared store either"

echo "── §6 two repos' legacy <pr>.json files are never collapsed"
# clear §5's deliberate divergence first, so this section's summaries are unambiguous
mint "$BOX1" "$KEY" "2026-10-23T10:00:00Z" "$HEAD_A"
mint_legacy "$BOX1" 441 "2026-10-20T09:00:00Z" "$HEAD_A"      # no repo field — unattributable
mint_legacy "$BOX2" 441 "2026-10-20T11:00:00Z" "$HEAD_B"      # a DIFFERENT repo's #441, same filename
OUT="$(rs "$BOX1" push)"
assert_contains "$OUT" "unkeyed=1" "§6 the repo-less legacy record is counted unkeyed"
if [ -z "$(ref_of "$STORE" 441)" ]; then ok "§6 no ref was minted for an unattributable legacy record"; else bad "§6 an unattributable legacy record was replicated"; fi
rs "$BOX2" union >/dev/null
assert_contains "$(command cat "$BOX2/441.json")" "$HEAD_B" "§6 box 2's own legacy 441.json is not replaced"
assert_absent "$BOX2" "$BOX2/daniel-ospina-agent-infra-441.json" "§6 no qualified file was invented from an unattributable legacy record"
# a legacy record that DOES name its repo is keyed by that repo (and the legacy file is kept)
mint_legacy_repo "$BOX1" 441 "2026-10-20T12:00:00Z" "$HEAD_C" "daniel-ospina/tortoise"
OUT="$(rs "$BOX1" push)"
assert_contains "$OUT" "pushed daniel-ospina-tortoise-441" "§6 a legacy record WITH a repo is keyed by that repo"
if [ -f "$BOX1/441.json" ]; then ok "§6 ...and its legacy file is left in place (no rename, no delete)"; else bad "§6 the legacy file was consumed"; fi

echo "── §7 idempotence: a second union changes nothing"
rs "$BOX2" union >/dev/null                                   # converge both directions first
D1="$(digest "$BOX2")"
REFS1="$(git -C "$STORE" for-each-ref --format='%(refname)' refs/reviews | wc -l | tr -d ' ')"
OUT="$(rs "$BOX2" union)"
assert_eq "$(digest "$BOX2")" "$D1" "§7 the registry digest is UNCHANGED by a second run"
assert_eq "$(git -C "$STORE" for-each-ref --format='%(refname)' refs/reviews | wc -l | tr -d ' ')" "$REFS1" \
  "§7 no ref was created by a second run"
assert_contains "$OUT" "wrote=0" "§7 the summary reports zero writes"
assert_contains "$OUT" "pushed=0" "§7 the summary reports zero pushes"

echo "── §8 status names what only the peer has"
mint "$BOX1" "daniel-ospina-tortoise-9999" "2026-10-28T10:00:00Z" "$HEAD_A" "daniel-ospina/tortoise" 9999
rs "$BOX1" push >/dev/null
OUT="$(rs "$BOX2" status)"
assert_contains "$OUT" "origin records=" "§8 status reports the shared store's record count"
assert_contains "$OUT" "local  records=" "§8 status reports this box's record count"
assert_contains "$(rs "$BOX2" status)" "newest_reviewed_at=2026-10-28T10:00:00Z" \
  "§8 the shared store's newest reviewed_at is the newest record on it"
assert_contains "$OUT" "missing here: daniel-ospina-tortoise-9999" "§8 status names the record missing here"
assert_contains "$(rs "$BOX2" pull)" "pulled daniel-ospina-tortoise-9999" "§8 ...and pull closes it"

echo "── §11 a peer record whose stamp cannot be read is NEVER overwritten"
# Regression (review cycle 1, P0): the peer record existed but its `reviewed_at` was unreadable,
# so push fell through both comparison arms and REPLACED the peer's bytes — rule 1 bypassed exactly
# where the ordering is unknown.
KEY2="daniel-ospina-tortoise-7777"
# The bad ref is built with PLUMBING: no verb of this script will create a record with no
# reviewed_at, and a test that relied on one of them would be asserting against a ref that was
# never written (the pre-fix shape of this section — it compared "" to "").
unstamped() { printf '{"pr":7777,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/tortoise"}\n' "$1"; }
seed_ref() { # <key> — publish a record with NO reviewed_at under a reviews ref
  local k="$1" b t c
  b="$(unstamped "$HEAD_A" | git -C "$STORE" hash-object -w --stdin)"
  t="$(printf '100644 blob %s\trecord.json\n' "$b" | git -C "$STORE" mktree)"
  c="$(git -C "$STORE" -c user.name=t -c user.email=t@t.invalid commit-tree "$t" -m "seed unstamped")"
  git -C "$STORE" push -q origin "$c:refs/reviews/$k"
  git -C "$STORE" update-ref "refs/reviews/$k" "$c"
}
seed_ref "$KEY2"
PEER_BYTES="$(git -C "$STORE" show "refs/reviews/$KEY2:record.json")"
if [ -n "$PEER_BYTES" ]; then ok "§11 fixture: the peer ref exists with an unreadable stamp"; else bad "§11 fixture: seed_ref produced no ref"; fi
mint "$BOX2" "$KEY2" "2026-10-25T10:00:00Z" "$HEAD_C" "daniel-ospina/tortoise" 7777
OUT="$(rs "$BOX2" push)"
assert_contains "$OUT" "which side is newer is UNKNOWN" "§11 push names the unknown-order refusal"
assert_contains "$OUT" "unreadable=1" "§11 ...and counts it"
assert_eq "$(git -C "$STORE" show "refs/reviews/$KEY2:record.json")" "$PEER_BYTES" \
  "§11 the peer's bytes are unchanged (no force-push over a record whose age is unknown)"

# §11b — the SAME protection for a peer ref whose tree carries NO record.json at all. `remote_record`
# yields empty for "no ref" and for "a ref with no readable record", and the push arm used to treat
# both as absent, silently replacing the peer's ref (pull_one already called this state a DEFECT).
KEY6="daniel-ospina-tortoise-3333"
seed_empty_ref() { # <key> — publish a reviews ref whose tree holds no record.json
  local k="$1" b t c
  b="$(printf 'not a record\n' | git -C "$STORE" hash-object -w --stdin)"
  t="$(printf '100644 blob %s\tother.txt\n' "$b" | git -C "$STORE" mktree)"
  c="$(git -C "$STORE" -c user.name=t -c user.email=t@t.invalid commit-tree "$t" -m "seed no-record")"
  git -C "$STORE" push -q origin "$c:refs/reviews/$k"
  git -C "$STORE" update-ref "refs/reviews/$k" "$c"
}
seed_empty_ref "$KEY6"
mint "$BOX2" "$KEY6" "2026-10-25T11:00:00Z" "$HEAD_C" "daniel-ospina/tortoise" 3333
OUT="$(rs "$BOX2" push)"
assert_contains "$OUT" "carries no readable record.json" "§11b push names the unreadable peer ref"
assert_contains "$OUT" "unreadable=2" "§11b ...and counts it (this run also re-skips §11's unreadable stamp)"
B6="$(git -C "$STORE" show "refs/reviews/$KEY6:other.txt" 2>/dev/null || true)"
assert_eq "$B6" "not a record" "§11b the peer's ref was NOT replaced"

echo "── §12 a NEWER legacy <pr>.json is not shadowed by an older qualified pull"
# Regression (review cycle 1, P1): the reader (atomic-land read_record) prefers the qualified name
# and falls back to a legacy <pr>.json. Comparing only the qualified path let an OLDER peer record
# be materialised beside a NEWER legacy one, silently shadowing the newer verdict.
KEY3="daniel-ospina-agent-infra-8888"
printf '{"pr":8888,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-26T10:00:00Z"}\n' "$HEAD_C" \
  > "$BOX2/8888.json"                                      # NEWER, legacy-named
mint "$BOX1" "$KEY3" "2026-10-20T10:00:00Z" "$HEAD_A" "daniel-ospina/agent-infra" 8888   # OLDER, qualified
rs "$BOX1" push >/dev/null
OUT="$(rs "$BOX2" pull)"
assert_contains "$OUT" "keep $KEY3" "§12 the older qualified record does not overwrite the newer legacy one"
assert_absent "$BOX2" "$BOX2/$KEY3.json" "§12 no qualified file was written to shadow it"
assert_contains "$(command cat "$BOX2/8888.json")" "$HEAD_C" "§12 the newer legacy verdict is still what the reader sees"

echo "── §13 status reports REAL numbers (not a placeholder)"
OUT="$(rs "$BOX2" status)"
# Assert the VALUES, not the labels — a counter computed inside a subshell prints the label with a
# zero, and a label-only assertion here let exactly that regression back in (review cycle 3, P2).
LOCAL_LINE="$(printf '%s\n' "$OUT" | grep '^local  records=')"
assert_contains "$LOCAL_LINE" "newest_reviewed_at=2026-10-28T10:00:00Z" \
  "§13 the LOCAL line carries the newest local reviewed_at (not 'none')"
assert_contains "$LOCAL_LINE" "records=$(python3 - "$BOX2" <<'PY'
import glob, json, os, sys
n = 0
for f in glob.glob(os.path.join(sys.argv[1], '*.json')):
    try:
        r = json.load(open(f))
    except Exception:
        continue
    if isinstance(r.get('pr'), int) and isinstance(r.get('repo'), str) and r['repo'].count('/') == 1:
        n += 1
print(n)
PY
)" \
  "§13 ...and the local record COUNT matches the attributable files (a subshell loses it to 0)"
assert_contains "$OUT" "origin records=" "§13 status reports the origin line too"
# 0, and that is the point of the reader-aware test: this box holds BOTH of those records under a
# LEGACY name the reader accepts (`8888.json` from §12, and the repo-less `441.json`), so reporting
# them as missing would contradict every other verb — `pull` correctly refuses to materialise them.
assert_contains "$OUT" "missing_here=0" "§13 status does not report a record the READER already finds (legacy included)"
assert_eq "$(printf '%s\n' "$OUT" | grep -c 'missing here:')" "0" "§13 ...and names none of them"
RS_LAST="$(rsx "$STORE" "$BOX2" status 2>&1)"; RS_RC=$?
assert_eq "$RS_RC" "0" "§13 status exits 0 when a record is MISSING here (missing != unreadable)"
mint "$BOX1" "daniel-ospina-tortoise-5555" "2026-10-27T10:00:00Z" "$HEAD_A" "daniel-ospina/tortoise" 5555
rs "$BOX1" push >/dev/null
RS_LAST="$(rsx "$STORE" "$BOX2" status 2>&1)"; RS_RC=$?
assert_eq "$RS_RC" "0" "§13 status stays 0 with a genuinely missing record"
assert_contains "$RS_LAST" "missing here: daniel-ospina-tortoise-5555" "§13 ...and still names it"

echo "── §14 a CARRIED record supersedes the record it carries (same mint time)"
# Regression (review cycle 2, P1): record-review.sh's carry arm keeps `reviewed_at` and changes the
# head, so a carried record is born at the SAME stamp as the record it supersedes. Reading that as
# a rule-4 conflict meant a carried verdict could NEVER be published, leaving the store pinned to
# the pre-carry head — the exact arm atomic-land.sh is built around.
KEY4="daniel-ospina-agent-infra-6666"
mint "$BOX1" "$KEY4" "2026-10-29T10:00:00Z" "$HEAD_A" "daniel-ospina/agent-infra" 6666
rs "$BOX1" push >/dev/null
carried() { # <dir> <key> <carried_from> <new head> — same reviewed_at, mint=carried
  printf '{"pr":6666,"head_sha":"%s","mint":"carried","carried_from":"%s","carried_at":"2026-10-30T10:00:00Z","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-29T10:00:00Z"}\n' \
    "$4" "$3" > "$1/$2.json"
}
carried "$BOX2" "$KEY4" "$HEAD_A" "$HEAD_B"
OUT="$(rs "$BOX2" push)"
assert_contains "$OUT" "CARRIES the peer's" "§14 the carry is recognised as a supersession, not a conflict"
assert_contains "$OUT" "conflicts=0" "§14 ...and it is not reported as divergence"
assert_contains "$(git -C "$STORE" show "refs/reviews/$KEY4:record.json")" "$HEAD_B" \
  "§14 the store now holds the CARRIED head (a carried verdict can reach the fleet)"
# the same supersession in the PULLING direction
mint "$BOX1" "$KEY4" "2026-10-29T10:00:00Z" "$HEAD_A" "daniel-ospina/agent-infra" 6666   # box 1 back to pre-carry bytes
OUT="$(rs "$BOX1" pull)"
assert_contains "$OUT" "CARRIES this box's" "§14 pull names the carry it is taking"
assert_contains "$(command cat "$BOX1/$KEY4.json")" "$HEAD_B" "§14 ...and box 1 holds the carried head"
# but a real disagreement at the same stamp is still a CONFLICT
mint "$BOX1" "$KEY4" "2026-10-29T10:00:00Z" "$HEAD_C" "daniel-ospina/agent-infra" 6666   # fresh, neither carries
assert_contains "$(rs "$BOX1" pull)" "CONFLICT $KEY4" "§14 a genuine same-stamp disagreement is still a CONFLICT"
# Clear §14's deliberate divergence, so every later section's summary is unambiguous — the same
# hygiene §6 applies to §5's. Box 1 goes back onto the record the store holds.
carried "$BOX1" "$KEY4" "$HEAD_A" "$HEAD_B"
rs "$BOX1" push >/dev/null 2>&1 || true

echo "── §15 a REFUSED push re-takes the decision instead of re-pushing blind"
# Regression (review cycle 2, P0): the retry re-read the ref only to acquire a lease value, so it
# force-pushed over whatever the peer had published meanwhile. Here the store rejects the first
# push; the retry must succeed, and it must do so through the same decision.
KEY5="daniel-ospina-agent-infra-4444"
mkdir -p "$ORIGIN/hooks"
printf '#!/bin/sh\nif [ -f "%s/reject-once" ]; then rm -f "%s/reject-once"; echo transient >&2; exit 1; fi\nexit 0\n' \
  "$T" "$T" > "$ORIGIN/hooks/pre-receive"
chmod +x "$ORIGIN/hooks/pre-receive"
mint "$BOX2" "$KEY5" "2026-10-31T10:00:00Z" "$HEAD_A" "daniel-ospina/agent-infra" 4444
touch "$T/reject-once"
OUT="$(rs "$BOX2" push)"
assert_contains "$OUT" "pushed $KEY5" "§15 the retry publishes after a transient refusal"
assert_contains "$OUT" "conflicts=0" "§15 the retry does not manufacture a conflict"
assert_contains "$(git -C "$STORE" show "refs/reviews/$KEY5:record.json")" "$HEAD_A" \
  "§15 the published record is the one the decision approved"

echo "── §16 the lease names the value the DECISION compared (not the remote's current value)"
# Regression (review cycle 3, P0 — reproduced before the fix): the push re-fetched AFTER deciding and
# then read the lease value from the just-fetched ref, so the fence always named the remote's CURRENT
# value. The push was an unconditional force in disguise, and a NEWER peer record was replaced by
# this box's OLDER one. Scenario: box 2 fetches, decides, and the peer moves the ref before the push
# lands (here: a client pre-push hook that fires during the FIRST push of the run).
KEY9="daniel-ospina-tortoise-10"                  # sorts FIRST: its push is the mid-run trigger
KEY8="daniel-ospina-tortoise-1111"                # the contended ref, decided later in the same run
OLD_JSON='{"pr":1111,"head_sha":"'"$HEAD_B"'","verdict":"clean","repo":"daniel-ospina/tortoise","reviewed_at":"2026-10-18T10:00:00Z"}'
NEW_JSON='{"pr":1111,"head_sha":"'"$HEAD_C"'","verdict":"clean","repo":"daniel-ospina/tortoise","reviewed_at":"2026-10-25T10:00:00Z"}'
_commit_of() { # <json> -> commit sha whose tree carries record.json
  local blob tree
  blob="$(printf '%s\n' "$1" | git -C "$STORE" hash-object -w --stdin)"
  tree="$(printf '100644 blob %s\trecord.json\n' "$blob" | git -C "$STORE" mktree)"
  git -C "$STORE" -c user.name=peer -c user.email=peer@localhost commit-tree "$tree" -m "peer record"
}
PEER_OLD="$(_commit_of "$OLD_JSON")"
PEER_NEW="$(_commit_of "$NEW_JSON")"
git -C "$STORE" push -q origin "$PEER_OLD:refs/reviews/$KEY8"      # the peer's OLDER record is live
git -C "$STORE" push -q origin "$PEER_NEW:refs/peer-objects/new"   # make the NEWER commit reachable there
mint "$BOX1" "$KEY9" "2026-10-20T10:00:00Z" "$HEAD_A" "daniel-ospina/tortoise" 10
rs "$BOX1" push >/dev/null                                          # box 1 publishes the trigger key
mint "$BOX2" "$KEY9" "2026-10-22T10:00:00Z" "$HEAD_A" "daniel-ospina/tortoise" 10   # NEWER: box 2 pushes it
mint "$BOX2" "$KEY8" "2026-10-20T10:00:00Z" "$HEAD_A" "daniel-ospina/tortoise" 1111 # OLDER than peer's NEW
HOOKS="$(git -C "$STORE" rev-parse --absolute-git-dir)/hooks"   # absolute: cwd is this WORKTREE
mkdir -p "$HOOKS"
{
  printf '#!/bin/sh\n'
  printf 'if [ -f "%s/inject" ]; then\n' "$T"
  printf '  rm -f "%s/inject"\n' "$T"
  printf '  git -C "%s" update-ref refs/reviews/%s %s && echo "injected %s" >> "%s/hook.log"\n' \
    "$ORIGIN" "$KEY8" "$PEER_NEW" "$PEER_NEW" "$T"
  printf 'fi\nexit 0\n'
} > "$HOOKS/pre-push"
chmod +x "$HOOKS/pre-push"
touch "$T/inject"
rs_rc "$BOX2" push
# NON-VACUITY: if the peer write never landed, the lease assertions below would pass for the wrong
# reason. The hook's own log is the proof it landed DURING the run, before the contended push.
assert_contains "$(command cat "$T/hook.log" 2>/dev/null || true)" "injected $PEER_NEW" \
  "§16 (setup) the peer's NEWER record landed mid-run, before the contended push"
assert_contains "$RS_LAST" "pushed $KEY9" "§16 (setup) the trigger key published"
assert_contains "$RS_LAST" "keep $KEY8" "§16 this box's OLDER record is refused against the newer peer one"
assert_eq "$(git -C "$STORE" show "refs/reviews/$KEY8:record.json" 2>/dev/null | sed -n 's/.*"reviewed_at":"\([^"]*\)".*/\1/p')" \
  "2026-10-25T10:00:00Z" "§16 the peer's NEWER record SURVIVED (the lease is a real fence)"
rm -f "$HOOKS/pre-push" "$T/inject"

echo "── §17 pull refuses a MIS-KEYED record (rule 3 holds on the way IN, not only out)"
# Regression (review cycle 3, P1 — reproduced): pull wrote a `refs/reviews/<key>` payload to
# `<key>.json` without checking the record's own repo/pr, so a mis-keyed ref transplanted another
# repo's verdict onto this PR's file (`read_record` validates only head_sha/verdict — #426).
MIS_JSON='{"pr":999,"head_sha":"'"$HEAD_A"'","verdict":"clean","repo":"other/repo","reviewed_at":"2026-10-25T10:00:00Z"}'
MIS_BLOB="$(printf '%s\n' "$MIS_JSON" | git -C "$STORE" hash-object -w --stdin)"
MIS_TREE="$(printf '100644 blob %s\trecord.json\n' "$MIS_BLOB" | git -C "$STORE" mktree)"
MIS_COMMIT="$(git -C "$STORE" -c user.name=mis -c user.email=mis@localhost commit-tree "$MIS_TREE" -m miskeyed)"
git -C "$STORE" push -q origin "$MIS_COMMIT:refs/reviews/daniel-ospina-tortoise-1010"
rs_rc "$BOX2" pull
assert_contains "$RS_LAST" "says other/repo#999" "§17 pull names the mis-keyed record it will not materialise"
assert_absent "$BOX2" "$BOX2/daniel-ospina-tortoise-1010.json" "§17 ...and writes NOTHING under that key"
assert_eq "$RS_RC" "4" "§17 ...and an unusable record is not reported as converged"

echo "── §9 fail-closed: an unreadable remote is UNKNOWN, never empty"
BAD="$T/badstore"
git clone -q "$ORIGIN" "$BAD" 2>/dev/null
git -C "$BAD" remote set-url origin "$T/does-not-exist.git"
RS_LAST="$(rsx "$BAD" "$BOX2" pull 2>&1)"; RS_RC=$?
assert_eq "$RS_RC" "1" "§9 an unreachable registry is a non-zero exit"
assert_contains "$RS_LAST" "UNKNOWN, not empty" "§9 ...and it says the store is UNKNOWN rather than silently 'converged'"

echo "── §10 nothing was deleted by any run above"
for f in "$KEY" "$KEY2" "$KEY3" 441 8888; do
  if [ -f "$BOX1/$f.json" ] || [ -f "$BOX2/$f.json" ]; then ok "§10 $f.json still exists on a box"; else bad "§10 $f.json vanished"; fi
done
assert_contains "$(git -C "$STORE" for-each-ref --format='%(refname:strip=2)' refs/reviews | LC_ALL=C sort | tr '\n' ' ')" \
  "daniel-ospina-agent-infra-2374" "§10 the PR's ref survived every run"
for r in "$KEY2" "$KEY3" daniel-ospina-tortoise-441 daniel-ospina-tortoise-9999; do
  if [ -n "$(ref_of "$STORE" "$r")" ]; then ok "§10 ref $r survived every run"; else bad "§10 ref $r vanished"; fi
done

# publish arbitrary bytes under a reviews ref — PLUMBING: no verb of this script writes these
seed_payload() { # <store-checkout> <key> <payload-line>
  local st="$1" k="$2" p="$3" b t c
  b="$(printf '%s\n' "$p" | git -C "$st" hash-object -w --stdin)"
  t="$(printf '100644 blob %s\trecord.json\n' "$b" | git -C "$st" mktree)"
  c="$(git -C "$st" -c user.name=t -c user.email=t@t.invalid commit-tree "$t" -m "seed payload")"
  git -C "$st" push -q --force origin "$c:refs/reviews/$k"
  git -C "$st" update-ref "refs/reviews/$k" "$c"
}

# ═══ 18–23. review cycle 1 (fresh-context reviewers B, C, E, A) ═════════════════════════════

echo "── §18 the STORE is the truth: a ref deleted out-of-band is re-published, never 'same'"
# Review cycle 1 (P1): the key list was read from this checkout's LOCAL refs/reviews/*, a cache the
# fetch maintains and never prunes. After a deletion on the store, `push` compared the record to a
# cached copy of ITSELF, answered `same`, pushed nothing, and exited 0 while the store held nothing —
# and `status` printed an `origin records=N` the store did not have.
KEYA="daniel-ospina-agent-infra-1212"
mint "$BOX1" "$KEYA" "2026-11-01T10:00:00Z" "$HEAD_A" "daniel-ospina/agent-infra" 1212
rs "$BOX1" push >/dev/null
assert_contains "$(git -C "$STORE" ls-remote --refs origin "refs/reviews/$KEYA")" "refs/reviews/$KEYA" \
  "§18 precondition: the record reached the store"
# delete it on the STORE only — the local cache keeps its ref on purpose (the fetch is not --prune)
git -C "$STORE" push -q origin ":refs/reviews/$KEYA"
assert_eq "$(git -C "$STORE" ls-remote --refs origin "refs/reviews/$KEYA")" "" \
  "§18 precondition: the store no longer has the ref (the local cache still does)"
# ═══ 23 (asserted HERE, where the two sources DISAGREE) ═════════════════════════════════
# While the deletion is in place the store lists one FEWER ref than the local cache, so a
# cache-sourced count is distinguishable here and only here (after the re-push below the two sets
# coincide and both reads agree — a count assertion there cannot discriminate).
CACHE_N="$(git -C "$STORE" for-each-ref --format='%(refname)' refs/reviews | wc -l | tr -d ' ')"
STORE_N="$(git -C "$STORE" ls-remote --refs origin 'refs/reviews/*' | wc -l | tr -d ' ')"
if [ "$STORE_N" -lt "$CACHE_N" ]; then
  ok "§18 (premise) the store lists FEWER refs than the local cache ($STORE_N < $CACHE_N)"
else
  bad "§18 (premise) store ($STORE_N) and cache ($CACHE_N) agree — the count assertion cannot discriminate"
fi
assert_contains "$(rs "$BOX1" status)" "origin records=$STORE_N" \
  "§23 status reports the STORE's count while the local cache disagrees"
OUT="$(rs "$BOX1" push)"
assert_contains "$OUT" "pushed $KEYA" "§18 push RE-PUBLISHES a store ref deleted out of band (not 'same')"
assert_contains "$OUT" "pushed=1" "§18 ...and counts it as real work, not as an identical record"
assert_contains "$(git -C "$STORE" ls-remote --refs origin "refs/reviews/$KEYA")" "refs/reviews/$KEYA" \
  "§18 ...and the store holds it again"

# ═══ 19. a peer record the rail cannot USE never wins the ordering ══════════════
# A store of its OWN, so the `exit 4` here cannot be satisfied by another section's unreadable
# fixture (the §20 lesson, applied to the usability gate — verified by mutation: with the shared
# store the rc stayed 4 even when the gate was disabled).
echo "── §19 an unusable peer record never replaces a usable local one (exit 4, not converged)"
KEYB="daniel-ospina-agent-infra-1313"
ORIGIN3="$T/origin3.git"; STORE3="$T/store3"; BOX5="$T/box5"
git init -q --bare "$ORIGIN3"
mkdir -p "$STORE3" "$BOX5"
git -C "$STORE3" init -q
git -C "$STORE3" remote add origin "$ORIGIN3"
git -C "$STORE3" config user.email sync@test.invalid
git -C "$STORE3" config user.name  sync-test
git -C "$STORE3" commit -q --allow-empty -m seed
git -C "$STORE3" push -q origin HEAD:refs/heads/main
mint "$BOX5" "$KEYB" "2026-11-02T10:00:00Z" "$HEAD_A" "daniel-ospina/agent-infra" 1313
rsx "$STORE3" "$BOX5" push >/dev/null                         # box 5 holds a usable record
GOOD_B="$(command cat "$BOX5/$KEYB.json")"
# a NEWER stamp, but no head_sha and not strict JSON: the rail's reader refuses this outright
seed_payload "$STORE3" "$KEYB" '{"pr":1313,"verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2027-01-01T00:00:00Z"} GARBAGE'
RS_LAST="$(rsx "$STORE3" "$BOX5" pull 2>&1)"; RS_RC=$?
assert_eq "$RS_RC" "4" "§19 an unusable peer record is exit 4, not 'converged'"
assert_contains "$RS_LAST" "unreadable=1" "§19 ...and the ONLY unusable record in the store is the one skipped"
assert_contains "$RS_LAST" "not one this box's rail can USE" "§19 ...the skip NAMES why it was refused"
assert_eq "$(command cat "$BOX5/$KEYB.json")" "$GOOD_B" \
  "§19 the usable local record SURVIVED (a newer stamp does not let unreadable bytes win)"

# ═══ 20. a store of its OWN, holding only an unusable record, is exit 4 ════════
# (de-vacuumed from §17: that assertion was satisfied by §11/§11b's permanently-seeded
#  unreadable refs, so a mis-keyed record alone still reported rc 0 — measured.)
echo "── §20 a store whose ONLY record is unusable is NOT converged (de-vacuumed)"
ORIGIN2="$T/origin2.git"; STORE2="$T/store2"; BOX4="$T/box4"
git init -q --bare "$ORIGIN2"
mkdir -p "$STORE2" "$BOX4"
git -C "$STORE2" init -q
git -C "$STORE2" remote add origin "$ORIGIN2"
git -C "$STORE2" config user.email sync@test.invalid
git -C "$STORE2" config user.name  sync-test
git -C "$STORE2" commit -q --allow-empty -m seed
git -C "$STORE2" push -q origin HEAD:refs/heads/main
seed_payload "$STORE2" "daniel-ospina-tortoise-1414" '{"pr":999,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","verdict":"clean","repo":"other/repo","reviewed_at":"2026-11-03T10:00:00Z"}'
RS_LAST="$(rsx "$STORE2" "$BOX4" pull 2>&1)"; RS_RC=$?
assert_eq "$RS_RC" "4" "§20 a store whose ONLY record is unusable is exit 4 (not rc 0)"
assert_contains "$RS_LAST" "says other/repo#999" "§20 ...and it names the mis-keyed record"
assert_absent "$BOX4" "$BOX4/daniel-ospina-tortoise-1414.json" "§20 ...and materialises nothing under that key"

# ═══ 21. a PARALLEL carry is not a conflict ════════════════════════════════════
echo "── §21 a parallel carry (same head + stamp, different carried_from) is not a divergence"
KEYD="daniel-ospina-agent-infra-1515"
# this box carries H1→H3; the store holds the peer's carry of the SAME head from a different base
printf '{"pr":1515,"head_sha":"%s","mint":"carried","carried_from":"%s","carried_at":"2026-11-05T10:00:00Z","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-11-04T10:00:00Z"}\n' \
  "$HEAD_C" "$HEAD_B" > "$BOX1/$KEYD.json"
seed_payload "$STORE" "$KEYD" \
  '{"pr":1515,"head_sha":"cccccccccccccccccccccccccccccccccccccccc","mint":"carried","carried_from":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","carried_at":"2026-11-05T09:00:00Z","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-11-04T10:00:00Z"}'
rs_rc "$BOX1" push
assert_eq "$RS_RC" "0" "§21 the parallel carry is NOT a permanent divergence (rc 0)"
assert_contains "$RS_LAST" "conflicts=0" "§21 ...and no conflict is reported"
# the same code path in the PULL direction (rc is 4 here because §11/§11b's permanently-seeded
# unreadable refs are on this store — the point is that KEYD is NOT a conflict)
rs_rc "$BOX1" pull
assert_contains "$RS_LAST" "only carry provenance differs" "§21 ...and the pulling direction reads the same supersession"
if grep -qF "CONFLICT $KEYD" <<<"$RS_LAST"; then bad "§21 ...the pull reported a conflict for a parallel carry"; else ok "§21 ...and reports no conflict for it"; fi
# a genuinely different VERDICT at the same stamp is still a conflict
printf '{"pr":1515,"head_sha":"%s","mint":"carried","carried_from":"%s","verdict":"clean-micro","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-11-04T10:00:00Z"}\n' \
  "$HEAD_C" "$HEAD_B" > "$BOX1/$KEYD.json"
assert_contains "$(rs "$BOX1" push)" "CONFLICT $KEYD" "§21 a different VERDICT at one stamp is still a CONFLICT"

# ═══ 22. a legacy record is never published under a key its own fields deny ════
echo "── §22 a legacy <pr>.json whose own pr field denies its filename is never published"
printf '{"pr":552,"head_sha":"%s","verdict":"clean","repo":"daniel-ospina/tortoise","reviewed_at":"2026-11-06T10:00:00Z"}\n' \
  "$HEAD_A" > "$BOX1/551.json"
OUT="$(rs "$BOX1" push)"
assert_contains "$OUT" "the filename says #551" "§22 push NAMES the filename/record disagreement"
assert_eq "$(git -C "$STORE" ls-remote --refs origin refs/reviews/daniel-ospina-tortoise-551)" "" \
  "§22 ...and mints no ref its own payload denies (a ref nothing can delete)"
assert_contains "$OUT" "unkeyed=1" "§22 ...and counts it (rule 3 stays informational on the PUSH side)"

# ═══ 23. status counts the STORE, not this box's cache ═════════════════════════
# §23's second read: after the re-publish both sources agree, so this pins the VALUE either way.
echo "── §23b status's count after the re-publish"
N_STORE="$(git -C "$STORE" ls-remote --refs origin 'refs/reviews/*' | wc -l | tr -d ' ')"
assert_contains "$(rs "$BOX1" status)" "origin records=$N_STORE" \
  "§23 status's origin count EQUALS the store's ref count (value, not just the label)"

# ═══ 24. every network op is BOUNDED, and git cannot block on a prompt ════════
echo "── §24 network ops are bounded and cannot block on an invisible prompt"
SHIM="$T/shim"; mkdir -p "$SHIM"
REAL_GIT="$(command -v git)"
# The shim answers every NON-network git verb for real (store resolution must still work) and
# SLEEPS on the network verbs — a store that never answers, the state the bound exists for.
cat > "$SHIM/git" <<EOS
#!/bin/sh
case "\$*" in
  *ls-remote*|*fetch*|*push*)
    printf '%s' "\${GIT_TERMINAL_PROMPT:-<unset>}" > "$T/prompt-env"
    sleep 30 ;;
  *) exec "$REAL_GIT" "\$@" ;;
esac
EOS
chmod +x "$SHIM/git"
START="$(date +%s)"
# ⛔ THE ENV IS FORCED, not inherited: this harness (and every fleet agent shell) already exports
# GIT_TERMINAL_PROMPT=0, so a shim that simply reports the inherited value prints `0` even if `git_b`
# dropped its own assignment — an assertion satisfied by the ambient environment is not a test
# (verified by mutation: deleting git_b's assignment left the suite green until this sentinel
# existed). With a sentinel, only git_b's own export can produce `0`.
RS_LAST="$(GIT_TERMINAL_PROMPT=__ambient_must_not_win__ PATH="$SHIM:$PATH" bash "$SYNC" pull --repo "$STORE" --dir "$BOX2" --remote origin --timeout 2 2>&1)"; RS_RC=$?
ELAPSED=$(( $(date +%s) - START ))
assert_eq "$RS_RC" "1" "§24 a store that never answers is a non-zero exit (never a hang)"
if [ "$ELAPSED" -le 12 ]; then ok "§24 ...and the run was BOUNDED (${ELAPSED}s against a 30s stub)"; else bad "§24 the run hung for ${ELAPSED}s — the wall-clock bound is not wired"; fi
assert_eq "$(command cat "$T/prompt-env" 2>/dev/null)" "0" \
  "§24 ...and every git it spawns carries GIT_TERMINAL_PROMPT=0 (no invisible credential prompt)"
assert_contains "$RS_LAST" "UNKNOWN, not empty" "§24 ...and the refusal says the store is UNKNOWN, not empty"

# ═══ 10 (continued). nothing above deleted a record either ══════════════════════
for pair in "$BOX1:$KEYA" "$BOX5:$KEYB"; do
  b="${pair%%:*}"; f="${pair##*:}"
  if [ -f "$b/$f.json" ]; then ok "§18–19 $f.json still exists on $(basename "$b")"; else bad "§18–19 $f.json vanished"; fi
done

echo
echo "registry-sync.test.sh: PASS=$PASS FAIL=$FAIL"
SUMMARY_PRINTED=1
[ "$FAIL" -eq 0 ]
