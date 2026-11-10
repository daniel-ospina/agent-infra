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
#   §27 the spawn budget is O(1) in the record count (#3180), and §27b prices the NESTED shape the
#       fast path excludes (`mint:"delta"`), which the flat fixtures could not
#   §28 the pre-pass's `join` is pinned to the collation its inputs were sorted with, and a
#       pre-pass that cannot be computed is NAMED rather than reported as converged (#3249 P1)
#   §29 ⭐ THE FIELD READ IS THE READER'S PARSE (#2510): a record carrying a NESTED object is keyed
#       and ORDERED by its TOP level, exactly as `read_record`/`review-enforcer` read it
#   §30 the compare+write lock: a live holder is never stolen (including EPERM), a dead/pid-less or
#       pid-recycled lock IS reclaimed, and a lock that cannot be removed still exits within the bound
#   §31 a local record that is NEWER but unusable is NAMED (and `pull` is not sold as its remedy),
#       never reported as a converged-looking `keep`

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

# ── helpers for the #3894 review round (§29-§31) ──────────────────────────────────────
assert_not_contains() { if grep -qF -- "$2" <<<"$1"; then bad "$3 (unexpectedly present: $2)"; else ok "$3"; fi; }

# run_bounded <secs> <cmd…> → RB_OUT / RB_RC / RB_TIMED_OUT. Stock macOS has no GNU `timeout`, and
# the property under test (§30e) IS "it terminates" — so the bound has to be imposed from outside and
# a hang has to be OBSERVED, never waited out.
run_bounded() { # <secs> <cmd…>
  local secs="$1"; shift
  local log rcfile pid n
  log="$(mktemp "$T/bounded.XXXXXX")"; rcfile="$log.rc"
  ( "$@" >"$log" 2>&1; printf '%s' "$?" > "$rcfile" ) &
  pid=$!
  n=0
  while kill -0 "$pid" 2>/dev/null && [ "$n" -lt $((secs * 10)) ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 "$pid" 2>/dev/null; then
    RB_TIMED_OUT=1
    kill -9 "$pid" 2>/dev/null || :
    pkill -P "$pid" 2>/dev/null || :
    wait "$pid" 2>/dev/null || :
  else
    RB_TIMED_OUT=0
  fi
  RB_RC="$(command cat "$rcfile" 2>/dev/null || printf '?')"
  RB_OUT="$(command cat "$log" 2>/dev/null || :)"
  rm -f "$log" "$rcfile"
}

# mini_fixture <name> → a SELF-CONTAINED bare origin + store under $T/<name>, and MINI (a box's
# registry dir). §29-§31 each need a store holding ONE key: the lock arms cost the ~5 s serialisation
# bound per KEY, so a suite store with a dozen keys would make them cost a minute each, and the
# ordering/oracle arms must not be perturbed by the records §1-§28 put on the main store.
mini_fixture() { # <name>
  local d="$T/$1"
  mkdir -p "$d/reg"
  git init -q --bare "$d/origin.git"
  git init -q "$d/store"
  git -C "$d/store" remote add origin "$d/origin.git"
  MINI_ROOT="$d"; MINI="$d/reg"; MINI_STORE="$d/store"
}
mini_rs() { local dir="$1"; shift; bash "$SYNC" "$@" --repo "$MINI_STORE" --dir "$dir" --remote origin --timeout 30 2>&1; }

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
assert_contains "$RS_LAST" "differ only in carry provenance" "§21 ...and the pulling direction reads the same supersession"
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

# ═══ 25. cycle-2 findings: the two P1s the re-review reproduced ═════════════════

# (a) the usability gate reads the TOP LEVEL of the record, like the reader does. A nested 40-hex
#     `head_sha` (inside an `evidence` object) with an EMPTY top-level one must not pass: the old
#     sed-based check took the LAST match on the line and let these bytes replace a usable record.
echo "── §25 a nested head_sha does not satisfy the usability gate (the reader's parse, not a sed match)"
ORIGIN4="$T/origin4.git"; STORE4="$T/store4"; BOX6="$T/box6"
git init -q --bare "$ORIGIN4"
mkdir -p "$STORE4" "$BOX6"
git -C "$STORE4" init -q
git -C "$STORE4" remote add origin "$ORIGIN4"
git -C "$STORE4" config user.email sync@test.invalid
git -C "$STORE4" config user.name  sync-test
git -C "$STORE4" commit -q --allow-empty -m seed
git -C "$STORE4" push -q origin HEAD:refs/heads/main
KEYE="daniel-ospina-agent-infra-1616"
mint "$BOX6" "$KEYE" "2026-11-07T10:00:00Z" "$HEAD_A" "daniel-ospina/agent-infra" 1616
rsx "$STORE4" "$BOX6" push >/dev/null
GOOD_E="$(command cat "$BOX6/$KEYE.json")"
seed_payload "$STORE4" "$KEYE" '{"pr":1616,"head_sha":"","evidence":{"head_sha":"eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"},"verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2027-02-02T00:00:00Z"}'
RS_LAST="$(rsx "$STORE4" "$BOX6" pull 2>&1)"; RS_RC=$?
assert_eq "$RS_RC" "4" "§25 a record whose TOP-LEVEL head_sha is empty is refused (exit 4)"
assert_contains "$RS_LAST" "not one this box's rail can USE" "§25 ...and the skip is named"
assert_eq "$(command cat "$BOX6/$KEYE.json")" "$GOOD_E" \
  "§25 the usable record SURVIVED — a nested head_sha cannot impersonate the reader's field"

# (b) a CARRY may not supersede a DISAGREEING verdict. `supersedes` ran before the verdict
#     comparison, so a carried `clean` overwrote a peer's `not-clean` at the same mint time.
echo "── §25b a carry cannot overwrite a different VERDICT at the same mint time"
KEYF="daniel-ospina-agent-infra-1717"
seed_payload "$STORE4" "$KEYF" '{"pr":1717,"head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","mint":"fresh","verdict":"not-clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-11-08T10:00:00Z"}'
printf '{"pr":1717,"head_sha":"%s","mint":"carried","carried_from":"%s","carried_at":"2026-11-09T10:00:00Z","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-11-08T10:00:00Z"}\n' \
  "$HEAD_B" "$HEAD_A" > "$BOX6/$KEYF.json"
RS_LAST="$(rsx "$STORE4" "$BOX6" push 2>&1)"; RS_RC=$?
assert_eq "$RS_RC" "3" "§25b push REFUSES the carry over a different verdict (exit 3)"
assert_contains "$RS_LAST" "CONFLICT $KEYF" "§25b ...and reports it as a divergence"
assert_contains "$(git -C "$STORE4" show "$(git -C "$STORE4" ls-remote --refs origin "refs/reviews/$KEYF" | awk '{print $1}'):record.json")" "not-clean" \
  "§25b the peer's not-clean record was NOT overwritten"
RS_LAST="$(rsx "$STORE4" "$BOX6" pull 2>&1)"; RS_RC=$?
assert_eq "$RS_RC" "3" "§25b ...and the pulling direction refuses it too"
assert_contains "$(command cat "$BOX6/$KEYF.json")" "\"verdict\":\"clean\"" \
  "§25b the local record is untouched (the pull did not write)"

# ═══ 26. cycle-2 finding: a store ref whose OBJECTS were never fetched must not read as converged
# The pre-fix gate was `git rev-parse refs/reviews/<key>` — TRUE only when this box already cached
# the ref — so a fresh box whose fetch failed skipped every record with NO counter and exited 0.
echo "── §26 a listed store ref whose objects did not arrive is UNREADABLE, never 'converged'"
STORE5="$T/store5"; BOX7="$T/box7"
# A fresh box that has never seen the reviews namespace: fetch only the BRANCHES, so every
# refs/reviews object is genuinely absent. (A plain `git clone` of a LOCAL bare repo hardlinks the
# whole object store, which silently defeats this fixture — measured.)
git init -q "$STORE5"
git -C "$STORE5" remote add origin "$ORIGIN4"
git -C "$STORE5" fetch -q origin '+refs/heads/*:refs/remotes/origin/*'
mkdir -p "$BOX7"
SHIM2="$T/shim2"; mkdir -p "$SHIM2"
cat > "$SHIM2/git" <<EOS
#!/bin/sh
case "\$*" in
  *ls-remote*) exec "$REAL_GIT" "\$@" ;;
  *fetch*)     echo "fatal: could not write object" >&2; exit 128 ;;
  *)           exec "$REAL_GIT" "\$@" ;;
esac
EOS
chmod +x "$SHIM2/git"
RS_LAST="$(PATH="$SHIM2:$PATH" bash "$SYNC" pull --repo "$STORE5" --dir "$BOX7" --remote origin --timeout 10 2>&1)"; RS_RC=$?
assert_eq "$RS_RC" "4" "§26 a store whose objects could not be fetched is NOT converged (exit 4)"
assert_contains "$RS_LAST" "not readable here" "§26 ...and each such key is NAMED, not silently dropped"
assert_contains "$RS_LAST" "unreadable=" "§26 ...and counted"
assert_contains "$RS_LAST" "failed=0" "§26 ...as unreadable, not as a failed move"
if grep -qE 'unreadable=0' <<<"$RS_LAST"; then bad "§26 the run counted NOTHING despite receiving nothing"; else ok "§26 the counter is non-zero (the pre-fix arm reported 0/0 and exited 0)"; fi

# ═══ 27. THE SPAWN BUDGET (agent-infra#3180) ══════════════════════════════════════
# THE MEASURED DEFECT. `union` examined every record one at a time with ~21 process spawns each
# (store_oid's awk over the whole listing, git show, 3-8 `field` seds, a python3, a mktemp) — on
# records whose bytes were ALREADY identical on both sides. Measured on this harness: a converged
# 10-record union cost 291 spawns and 40 records cost 1,131 (21/record); a land carries 4,027
# records, so ~85,000 spawns before anything useful happened.
#
# The assertion is the SCALING, not a constant: any per-record cost makes the count grow with N, and
# no constant hides it. Mutation proof: delete the converged pre-pass from `do_pull` and this
# section goes red by hundreds.
echo "── §27 the spawn budget is O(1) in the number of records (the #3180 regression)"
SPAWN_SHIM="$T/spawn-shim"; mkdir -p "$SPAWN_SHIM"
for tool in git sed awk python3 comm join sort cut wc mktemp paste head cat tr cmp; do
  real_tool="$(command -v "/usr/bin/$tool" 2>/dev/null || command -v "$tool")"
  [ -n "$real_tool" ] || continue
  printf '#!/bin/sh\nprintf "%%s\\n" %s >> "${SPAWN_LOG:-/dev/null}"\nexec %s "$@"\n' "$tool" "$real_tool" > "$SPAWN_SHIM/$tool"
  chmod +x "$SPAWN_SHIM/$tool"
done
spawns_for_union() { # <root> <n> → "<spawns>\n<summary line>\n<stderr>"
  local rt="$1" n="$2" i pr out
  mkdir -p "$rt/reg"
  git init -q --bare "$rt/origin.git"
  git init -q "$rt/store"
  git -C "$rt/store" remote add origin "$rt/origin.git"
  i=1
  while [ "$i" -le "$n" ]; do
    pr=$((100 + i))
    printf '{"pr":%s,"head_sha":"%s","verdict":"clean","repo":"acme/widget","reviewed_at":"2026-01-01T00:%02d:00Z"}\n' \
      "$pr" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$i" > "$rt/reg/acme-widget-$pr.json"
    i=$((i + 1))
  done
  bash "$SYNC" union --repo "$rt/store" --dir "$rt/reg" --remote origin --timeout 30 >/dev/null 2>&1
  : > "$T/spawns.log"
  out="$(PATH="$SPAWN_SHIM:$PATH" SPAWN_LOG="$T/spawns.log" bash "$SYNC" union --repo "$rt/store" --dir "$rt/reg" --remote origin --timeout 30 2>&1)"
  printf '%s\n%s\n' "$(wc -l < "$T/spawns.log" | tr -d ' ')" "$out"
}
SP10="$(spawns_for_union "$T/n10" 10)"
SP25="$(spawns_for_union "$T/n25" 25)"
S10="$(head -1 <<<"$SP10" | tr -d ' ')"
S25="$(head -1 <<<"$SP25" | tr -d ' ')"
O10="$(tail -n +2 <<<"$SP10")"
echo "     spawns: N=10 → $S10   N=25 → $S25   (before #3180: 291 → 1131)"
case "$S10$S25" in
  ''|*[!0-9]*) bad "§27 could not count spawns (N=10='$S10', N=25='$S25')" ;;
  *)
    DELTA=$((S25 - S10))
    if [ "$DELTA" -le 2 ]; then
      ok "§27 the spawn count is FLAT in N (N=10 → $S10, N=25 → $S25, delta $DELTA)"
    else
      bad "§27 spawns grow with the record count (N=10 → $S10, N=25 → $S25, delta $DELTA) — the per-record path is still walked"
    fi ;;
esac
assert_contains "$O10" "same=20" "§27 a converged union counts each record ONCE PER HALF (same=2N)"
assert_contains "$O10" "unchanged=20" "§27 ...and reports the pre-pass's own count (unchanged=2N)"
assert_contains "$O10" "wrote=0" "§27 ...and writes nothing"
assert_contains "$O10" "pushed=0" "§27 ...and pushes nothing"
assert_contains "$O10" "nothing to sync" "§27 ...and says so on stderr (a converged run is never silent about it)"
# A converged run must never be able to skip a CHANGED record: one byte of difference and the record
# takes the full path again.
printf '{"pr":105,"head_sha":"%s","verdict":"clean","repo":"acme/widget","reviewed_at":"2026-02-01T00:00:00Z"}\n' \
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" > "$T/n10/reg/acme-widget-105.json"
ONE_CHANGED="$(bash "$SYNC" union --repo "$T/n10/store" --dir "$T/n10/reg" --remote origin --timeout 30 2>&1)"
assert_contains "$ONE_CHANGED" "unchanged=18" "§27 a ONE-BYTE change drops the pre-pass count (9 per half)"
assert_contains "$ONE_CHANGED" "pushed acme-widget-105" "§27 ...and the changed record is published"

# §27b — THE SHAPE THE FAST PATH EXCLUDES. Every fixture above is ONE FLAT LINE, so §27 prices the
# budget only for the shape `record-review.sh` writes for a `mint:"fresh"` record. It emits a NESTED
# `"delta":{…}` for `mint:"delta"` (record-review.sh:6483), and a nested record takes the `python3`
# path — so §27's "flat in N" claim said NOTHING about the shape that actually costs (review finding
# P2, PR #3894). Priced here instead, with the assertion each direction needs: the cost is a bounded
# constant PER RECORD (a nested record is anomalous by construction — 2 of 4,645 in the live
# registry, so a handful of spawns each is the intended trade), and it is NOT ZERO — a nested record
# that spawned nothing would mean the fast path READ it, which is §29's failure mode, not a win.
spawns_for_nested_pull() { # <root> <n> → "<spawns>\n<summary+stderr>"
  local rt="$1" n="$2" i pr out
  mkdir -p "$rt/reg" "$rt/fresh"
  git init -q --bare "$rt/origin.git"
  git init -q "$rt/store"
  git -C "$rt/store" remote add origin "$rt/origin.git"
  i=1
  while [ "$i" -le "$n" ]; do
    pr=$((100 + i))
    printf '{"pr":%s,"head_sha":"%s","mint":"delta","verdict":"clean","repo":"acme/widget","reviewed_at":"2026-01-01T00:%02d:00Z","delta":{"arm":"docs","from":"aaaaaaa","reviewed_at":"2000-01-01T00:00:00Z"}}\n' \
      "$pr" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$i" > "$rt/reg/acme-widget-$pr.json"
    i=$((i + 1))
  done
  # publish from the seed box, then measure a PULL into an empty box — the per-record path, not the
  # converged pre-pass (a converged nested registry would spawn nothing and prove nothing).
  bash "$SYNC" union --repo "$rt/store" --dir "$rt/reg" --remote origin --timeout 30 >/dev/null 2>&1
  : > "$T/spawns.log"
  out="$(PATH="$SPAWN_SHIM:$PATH" SPAWN_LOG="$T/spawns.log" bash "$SYNC" pull --repo "$rt/store" --dir "$rt/fresh" --remote origin --timeout 30 2>&1)"
  printf '%s\n%s\n' "$(wc -l < "$T/spawns.log" | tr -d ' ')" "$out"
}
NP4="$(spawns_for_nested_pull "$T/nest4" 4)"
NP10="$(spawns_for_nested_pull "$T/nest10" 10)"
NS4="$(head -1 <<<"$NP4" | tr -d ' ')"
NS10="$(head -1 <<<"$NP10" | tr -d ' ')"
NO10="$(tail -n +2 <<<"$NP10")"
echo "     nested-shape spawns: N=4 → $NS4   N=10 → $NS10"
assert_contains "$NO10" "pulled acme-widget-105" "§27b every NESTED record still CONVERGES (the shape gate is about cost, never semantics)"
case "$NS4$NS10" in
  ''|*[!0-9]*) bad "§27b could not count spawns (N=4='$NS4', N=10='$NS10')" ;;
  *)
    PDELTA=$((NS10 - NS4))
    # measured: the python path costs ~7 spawns per nested record (the reader-strict parse plus the
    # field reads it serves). The bound is 10/record — it must stay a SMALL CONSTANT, and it must
    # stay > 0 (see above): both directions are the assertion.
    if [ "$PDELTA" -gt 0 ] && [ "$PDELTA" -le $((10 * 6)) ]; then
      ok "§27b a nested record costs a BOUNDED constant ($((PDELTA / 6)) spawns/record, not O(N))"
    else
      bad "§27b a nested record's per-record cost is out of bounds (delta $PDELTA over 6 more records; want 1..60)"
    fi ;;
esac

# ═══ 28. the pre-pass's join is pinned to the collation its inputs were sorted with ══════
# Review finding P1 on PR #3249: `identical_pairs` sorted BOTH inputs `LC_ALL=C` and then ran an
# UNQUALIFIED `join`, so the merge was evaluated under the ambient locale over data ordered by C.
# The two disagree on a mixed-case key set (`Acme-Widget-101` is before `acme-widget-102` in C and
# after it under en_US), and a locale-collating `join` then mis-merges or refuses: measured on
# coreutils 9.4, `join --check-order` under en_US.utf8 prints "input is not in sorted order", exits
# 1 and emits only a PREFIX of the pairs. Every record then falls back to the per-record path (~21
# spawns apiece) — silently, because `identical_pairs` ended in `return 0`.
#
# The shim below IS such a join: it refuses unless the call carries `LC_ALL=C`, which is the property
# under test and is checkable on a host with NO non-C locale installed (the ambient locale is forced
# to `C.UTF-8`, a non-`C` STRING whether or not its collation actually differs). Reverting the fix
# makes this section red — the pre-pass then cannot run at all.
echo "── §28 the pre-pass's join is pinned to C (a mixed-case key set cannot disable it)"
LC_ROOT="$T/lc"; LC_REG="$LC_ROOT/reg"; LC_JOIN_SHIM="$T/lc-join-shim"
mkdir -p "$LC_REG" "$LC_JOIN_SHIM"
git init -q --bare "$LC_ROOT/origin.git"
git init -q "$LC_ROOT/store"
git -C "$LC_ROOT/store" remote add origin "$LC_ROOT/origin.git"
lc_record() { # <owner/repo> <pr> <n> — the key is DERIVED from repo+pr, exactly as local_keyed does
  local repo="$1" pr="$2" n="$3" key
  key="$(printf '%s-%s-%s' "${repo%%/*}" "${repo#*/}" "$pr")"
  printf '{"pr":%s,"head_sha":"%s","verdict":"clean","repo":"%s","reviewed_at":"2026-01-01T00:%02d:00Z"}\n' \
    "$pr" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "$repo" "$n" > "$LC_REG/$key.json"
}
lc_record Acme/Widget 201 1
lc_record acme/widget 202 2
lc_record _0dot/x     203 3
lc_record 9lives/x    204 4
lc_record Zeta/Beta   205 5
lc_record zeta/beta   206 6
# premise: the fixture really carries mixed-case keys (the discrimination is C-vs-locale ORDER)
if [ -f "$LC_REG/Acme-Widget-201.json" ] && [ -f "$LC_REG/acme-widget-202.json" ]; then
  ok "§28 (premise) the fixture carries mixed-case keys whose C order is not their locale order"
else
  bad "§28 (premise) the fixture lost its mixed-case keys"
fi
bash "$SYNC" union --repo "$LC_ROOT/store" --dir "$LC_REG" --remote origin --timeout 30 >/dev/null 2>&1
REAL_JOIN="$(command -v join)"
cat > "$LC_JOIN_SHIM/join" <<EOS
#!/bin/sh
printf '%s\n' "\${LC_ALL:-<unset>}" >> "$T/join.locale"
if [ "\${LC_ALL:-}" != "C" ]; then
  echo "join: input is not in sorted order" >&2
  exit 1
fi
exec "$REAL_JOIN" "\$@"
EOS
chmod +x "$LC_JOIN_SHIM/join"
: > "$T/join.locale"
LC28="$(LC_ALL=C.UTF-8 PATH="$LC_JOIN_SHIM:$PATH" bash "$SYNC" union --repo "$LC_ROOT/store" --dir "$LC_REG" --remote origin --timeout 30 2>&1)"
# NON-VACUITY: if `join` were never reached, the assertions below would pass for the wrong reason.
if [ -s "$T/join.locale" ]; then ok "§28 (premise) the emulated locale-collating join WAS invoked"; else bad "§28 (premise) join was never invoked — the pre-pass is not exercised"; fi
assert_eq "$(LC_ALL=C sort -u "$T/join.locale" | tr '\n' ' ')" "C " \
  "§28 every join call carries LC_ALL=C (the ambient locale is forced to C.UTF-8)"
assert_contains "$LC28" "unchanged=12" "§28 the pre-pass still skips all 6 records on both halves (2N)"
assert_contains "$LC28" "same=12" "§28 ...and the summary agrees the records were examined and identical"

# §28b — a pre-pass that genuinely cannot be computed is NAMED, not `return 0`-ed into silence.
# This is the other half of the P1: the rc is propagated, so `do_pull`/`do_push` take their existing
# all-records fallback and SAY SO. Correctness is untouched (every record still converges); what is
# recovered is the signal that the optimisation did not run.
cat > "$LC_JOIN_SHIM/join" <<EOS
#!/bin/sh
echo "join: input is not in sorted order" >&2
exit 1
EOS
chmod +x "$LC_JOIN_SHIM/join"
LC_LAST="$(LC_ALL=C.UTF-8 PATH="$LC_JOIN_SHIM:$PATH" bash "$SYNC" union --repo "$LC_ROOT/store" --dir "$LC_REG" --remote origin --timeout 30 2>&1)"; LC_RC=$?
assert_eq "$LC_RC" "0" "§28b a pre-pass that cannot be computed STILL converges (slower, never wrong)"
assert_contains "$LC_LAST" "the converged pre-pass could not run" "§28b ...and the fallback is NAMED instead of silently reported as converged"
assert_contains "$LC_LAST" "unchanged=0" "§28b ...reporting ZERO skipped rather than a count it did not compute"
assert_contains "$LC_LAST" "same=12" "§28b ...and every record still converges through the per-record path"

# ═══ 29. the field read IS the reader's parse ═══════════════════════════════════════
# Review finding P2 on PR #3894 — the PR's OWN subject, and nothing pinned it: reverting `field()` to
# the last-match implementation left this suite at 137/0 (measured, mutation run). The last-match scan
# took a NESTED value, while `read_record` (scripts/atomic-land.sh) and `extensions/review-enforcer`
# parse strict JSON and take the TOP-LEVEL one — two parsers, one artifact, opposite answers. The two
# decisions that depended on it are the two asserted here: rule 3's KEY check (`repo`/`pr`) and rule
# 1's ORDERING (`reviewed_at`).
# The fixture is the shape `record-review.sh` really emits for `mint:"delta"`: ONE line, one outer
# object, a NESTED `delta` object that DENIES the key and ranks the record older.
echo "── §29 field() reads the record's TOP level, exactly as the gate does"
mini_fixture nest
NEST_KEY="$KEY"
printf '{"pr":2374,"head_sha":"%s","mint":"delta","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-20T10:00:00Z","delta":{"arm":"docs","repo":"other/repo","pr":999,"reviewed_at":"2000-01-01T00:00:00Z"}}\n' \
  "$HEAD_A" > "$MINI/$NEST_KEY.json"
N_OUT="$(mini_rs "$MINI" union)"; N_RC=$?
assert_eq "$N_RC" "0" "§29 a nested-shape record PUBLISHES (its TOP level is its key)"
if [ -n "$(git -C "$MINI_STORE" ls-remote --refs origin "refs/reviews/$NEST_KEY")" ]; then
  ok "§29 ...under the key its TOP level names"
else
  bad "§29 ...NOT published — the read took the NESTED repo/pr, so rule 3 acted on the wrong value"
fi
assert_not_contains "$N_OUT" "name disagrees with the record's own repo/pr fields" "§29 ...and the run did not claim the name disagrees with the record"
NEST2D="$MINI_ROOT/box2"; mkdir -p "$NEST2D"
N2_OUT="$(mini_rs "$NEST2D" pull)"; N2_RC=$?
assert_eq "$N2_RC" "0" "§29 a fresh box pulls the nested record (exit 0, not 4)"
if [ -f "$NEST2D/$NEST_KEY.json" ] && cmp -s "$MINI/$NEST_KEY.json" "$NEST2D/$NEST_KEY.json"; then
  ok "§29 ...BYTE-IDENTICALLY — the nested object did not re-key it into another repo's slot"
else
  bad "§29 ...not materialised (the reader took the nested repo/pr)"
fi
assert_not_contains "$N2_OUT" "NOT this key" "§29 ...and the run did not report it as another repo's key"
# rule 1: the peer's TOP stamp (2026-10-20) outranks a local 2026-10-19, even though the peer's NESTED
# stamp (2000-01-01) is ancient. The old parse kept the local record and reported a converged-looking
# `keep` — a newer record silently lost, in the pull direction.
NEST3D="$MINI_ROOT/box3"; mkdir -p "$NEST3D"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-19T00:00:00Z"}\n' \
  "$HEAD_B" > "$NEST3D/$NEST_KEY.json"
N3_OUT="$(mini_rs "$NEST3D" pull)"
assert_contains "$N3_OUT" "pulled $NEST_KEY" "§29 the peer's TOP stamp outranks a local 2026-10-19 (rule 1 reads the top level)"
if cmp -s "$MINI/$NEST_KEY.json" "$NEST3D/$NEST_KEY.json"; then
  ok "§29 ...and the wall-clock-newer record REPLACED the local one"
else
  bad "§29 ...the local record was kept — the ordering used the NESTED reviewed_at"
fi
assert_not_contains "$N3_OUT" "this box is NEWER" "§29 ...and the run did not claim this box was newer"
# §29c — a record written by a STANDARD JSON serialiser. `json.dumps`'s default separators emit
# `": "`, and `field()`'s trims never skipped that whitespace, so the stamp came back as a single
# SPACE: non-empty, so every unreadable guard passed, and `' '` sorts below `'2'` — so `pull` decided
# the local record was OLDER and OVERWROTE a NEWER one with an older peer, silently, at rc 0. The
# shape gate is exactly where such a record must fall through to the reader's parse (review round 3).
NEST4D="$MINI_ROOT/box4"; mkdir -p "$NEST4D"
printf '{"pr": 2374, "head_sha": "%s", "mint": "fresh", "verdict": "clean", "repo": "daniel-ospina/agent-infra", "reviewed_at": "2026-10-25T00:00:00Z"}\n' \
  "$HEAD_C" > "$NEST4D/$NEST_KEY.json"
SPACED_BEFORE="$(digest "$NEST4D")"
N4_OUT="$(mini_rs "$NEST4D" pull)"
assert_eq "$(digest "$NEST4D")" "$SPACED_BEFORE" "§29c a spaced record (\": \") is READ, so its NEWER stamp is not overwritten by an older peer"
assert_contains "$N4_OUT" "this box is NEWER" "§29c ...and the run says so instead of reporting a write"
# §29d — ONE LINE means the second READ hit EOF. `[ -z "$l2" ]` cannot tell EOF from an EMPTY line, so
# `{"…"}\n\nGARBAGE\n` took the fast path while `json.load` refuses the whole file — and push then
# PUBLISHED a record every other box refuses. It must be unreadable here instead.
NEST5D="$MINI_ROOT/box5"; mkdir -p "$NEST5D"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-26T00:00:00Z"}\n\nGARBAGE\n' \
  "$HEAD_C" > "$NEST5D/$NEST_KEY.json"
N5_OUT="$(mini_rs "$NEST5D" push)"
assert_contains "$N5_OUT" "no repo field" "§29d a record with a BLANK second line is not read by the fast path (it is not one line)"
# the store already holds this key from §29a; the point is that THIS record was never published as a
# NEW one — it was refused outright rather than published under a key its payload cannot back.
assert_not_contains "$N5_OUT" "pushed $NEST_KEY" "§29d ...so it is never published"
# §29e — the other half of "one line": an UNTERMINATED second line still CARRIES data, so a test that
# only asks whether the second read FAILED accepts `{"…"}\nJUNK` while `json.load` refuses the file
# (round 4, measured end-to-end: a corrupt local file won rule 1/rule 4 at rc 0 with `unreadable=0`,
# replaced a usable peer record, and left the store holding bytes no box can read).
NEST6D="$MINI_ROOT/box6"; mkdir -p "$NEST6D"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-27T00:00:00Z"}\nJUNK' \
  "$HEAD_C" > "$NEST6D/$NEST_KEY.json"
N6_OUT="$(mini_rs "$NEST6D" push)"
assert_contains "$N6_OUT" "no repo field" "§29e a record whose second line carries junk (no trailing newline) is NOT read by the fast path"
assert_not_contains "$N6_OUT" "pushed $NEST_KEY" "§29e ...and a record the strict reader REFUSES is never published"
# §29f — a LEGAL JSON escape must be read the way the reader reads it. `\/` is valid inside a string and
# `read_record` accepts it; a prefix trim cannot decode it, so the fast path read `repo` as
# `daniel-ospina\/agent-infra`, decided the key did not match, and refused a record the gate would use
# (round 4). Escapes are now routed to the strict parse.
NEST7D="$MINI_ROOT/box7"; mkdir -p "$NEST7D"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina\\/agent-infra","reviewed_at":"2026-10-28T00:00:00Z"}\n' \
  "$HEAD_C" > "$NEST7D/$NEST_KEY.json"
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$NEST7D/$NEST_KEY.json" 2>/dev/null; then
  ok "§29f (premise) the fixture is VALID JSON the reader accepts"
else
  bad "§29f (premise) the fixture is not valid JSON — the arm would prove nothing"
fi
N7_OUT="$(mini_rs "$NEST7D" push)"
assert_contains "$N7_OUT" "pushed $NEST_KEY" "§29f a legal JSON escape is decoded, so its key is accepted (not mis-keyed)"
assert_not_contains "$N7_OUT" "not this key" "§29f ...and the run did not report a key mismatch"
# §29g — a DUPLICATE key, the last one written with whitespace before its colon (legal JSON). `json.load`
# takes the LAST; an exact-byte last-match scan cannot see this form and takes an EARLIER one, so rule 3
# published a record under a key its own strict fields DENY (round 5, measured end-to-end).
NEST8D="$MINI_ROOT/box8"; mkdir -p "$NEST8D"
printf '{"pr":2374,"repo":"daniel-ospina/agent-infra","repo" :"other/repo","head_sha":"%s","mint":"fresh","verdict":"clean","reviewed_at":"2026-10-29T00:00:00Z"}\n' \
  "$HEAD_A" > "$NEST8D/$NEST_KEY.json"
if python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repo"])' "$NEST8D/$NEST_KEY.json" 2>/dev/null | grep -q '^other/repo$'; then
  ok "§29g (premise) the strict reader takes the LAST duplicate (repo=other/repo)"
else
  bad "§29g (premise) the fixture does not have the duplicate shape the arm needs"
fi
N8_OUT="$(mini_rs "$NEST8D" push)"
assert_not_contains "$N8_OUT" "pushed $NEST_KEY" "§29g a DUPLICATE key is resolved by the reader, so the record is refused rather than published"
assert_not_contains "$N8_OUT" "pushed " "§29g ...and nothing at all was published"
# §29n — a repeat in the EXACT byte form. `json.load` takes the LAST, and this scan's greedy `##*` does
# too; the arm pins that direction, because taking the FIRST would key the record by the earlier value
# while every reader used the later one (rule 3 publishes under a key its own fields deny).
NESTCD="$MINI_ROOT/boxc"; mkdir -p "$NESTCD"
printf '{"pr":2374,"repo":"daniel-ospina/agent-infra","repo":"other/repo","head_sha":"%s","mint":"fresh","verdict":"clean","reviewed_at":"2026-11-01T00:00:00Z"}\n' \
  "$HEAD_A" > "$NESTCD/$NEST_KEY.json"
NC_OUT="$(mini_rs "$NESTCD" push)"
assert_not_contains "$NC_OUT" "pushed $NEST_KEY" "§29n a plain duplicate key is resolved to the LAST occurrence, as the reader does"
# §29o — `NaN`/`Infinity` ARE NOT JSON. Python's `json.load` accepts them; `extensions/review-enforcer`
# (`JSON.parse`) REFUSES them. A non-finite stamp stringifies to `nan`, which sorts ABOVE every real
# timestamp, so the sync read it as the newest record in the store and OVERWROTE a newer peer one with
# bytes the gate cannot parse (round 6, reproduced end-to-end). Non-RFC constants are the strict parse's
# to reject, on both verbs.
NESTDD="$MINI_ROOT/boxd"; mkdir -p "$NESTDD"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":NaN}\n' \
  "$HEAD_A" > "$NESTDD/$NEST_KEY.json"
if node -e 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"))' "$NESTDD/$NEST_KEY.json" 2>/dev/null; then
  bad "§29o (premise) the gate's own reader ACCEPTED the fixture — the arm would prove nothing"
else
  ok "§29o (premise) the gate's own reader (JSON.parse) REFUSES the fixture"
fi
ND_OUT="$(mini_rs "$NESTDD" push)"
assert_not_contains "$ND_OUT" "pushed $NEST_KEY" "§29o a NaN stamp is UNUSABLE — never published"
assert_contains "$ND_OUT" "not one the fleet's rail can USE" "§29o ...and the refusal NAMES usability"
# §29q — THE PEER'S BYTES ARE AN ORDERING AUTHORITY ONLY IF THE READER CAN USE THEM. `push_decision` read
# the peer's `reviewed_at` with `field`, which happily reads a flat record strict JSON REFUSES — so an
# unreadable peer record whose TEXT said 2099 outranked a usable local record for ever: the run reported
# `keep — the peer is NEWER`, withheld this box's record, and called itself converged with
# `unreadable=0` (round 8, measured). The store's ref is planted with git plumbing because `push` now
# refuses to publish such a record — which is itself the point.
mini_fixture peerbad
PB_BOX="$MINI_ROOT/box"; mkdir -p "$PB_BOX"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-11-01T00:00:00Z"}\n' \
  "$HEAD_A" > "$PB_BOX/$NEST_KEY.json"
PB_PEER="$T/peerbad.peer"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2099-01-01T00:00:00Z",}\n' \
  "$HEAD_B" > "$PB_PEER"
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$PB_PEER" 2>/dev/null; then
  bad "§29q (premise) the planted peer record parses — it must NOT (a trailing comma)"
else
  ok "§29q (premise) the planted peer record is one the strict reader REFUSES"
fi
PB_BLOB="$(git -C "$MINI_STORE" hash-object -w "$PB_PEER")"
PB_TREE="$(printf '100644 blob %s\trecord.json\n' "$PB_BLOB" | git -C "$MINI_STORE" mktree)"
PB_COMMIT="$(git -C "$MINI_STORE" -c user.name=sync -c user.email=sync@test.invalid commit-tree "$PB_TREE" -m "$NEST_KEY")"
git -C "$MINI_STORE" push -q origin "$PB_COMMIT:refs/reviews/$NEST_KEY" 2>/dev/null || :
PB_OUT="$(mini_rs "$PB_BOX" push)"; PB_RC=$?
assert_eq "$PB_RC" "4" "§29q an UNREADABLE peer record cannot outrank this box's usable one (exit 4, not converged)"
assert_contains "$PB_OUT" "not one this box's rail can USE" "§29q ...and the run NAMES the peer's record as unreadable"
assert_not_contains "$PB_OUT" "the peer is NEWER" "§29q ...instead of claiming the peer is newer on bytes it cannot read"
# §29r — A STRING VALUE RUNS TO ITS CLOSING QUOTE, NEVER TO THE FIRST `,`. With the old prefix trim a
# verdict of `clean,partial` read as `clean`, so two same-stamp records that genuinely DISAGREE compared
# `same` and rule 4's divergence was never reported (round 9: reverting it left the suite green).
mini_fixture delim
DL_BOX="$MINI_ROOT/box"; mkdir -p "$DL_BOX"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-11-05T00:00:00Z"}\n' \
  "$HEAD_A" > "$DL_BOX/$NEST_KEY.json"
DL_PEER="$T/delim.peer"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean,partial","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-11-05T00:00:00Z"}\n' \
  "$HEAD_A" > "$DL_PEER"
DL_BLOB="$(git -C "$MINI_STORE" hash-object -w "$DL_PEER")"
DL_TREE="$(printf '100644 blob %s\trecord.json\n' "$DL_BLOB" | git -C "$MINI_STORE" mktree)"
DL_COMMIT="$(git -C "$MINI_STORE" -c user.name=sync -c user.email=sync@test.invalid commit-tree "$DL_TREE" -m "$NEST_KEY")"
git -C "$MINI_STORE" push -q origin "$DL_COMMIT:refs/reviews/$NEST_KEY" 2>/dev/null || :
if python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$DL_PEER" 2>/dev/null | grep -qx 'clean,partial'; then
  ok "§29r (premise) the peer's verdict really is the two-token value"
else
  bad "§29r (premise) the fixture lost its comma-carrying verdict"
fi
DL_OUT="$(mini_rs "$DL_BOX" push)"; DL_RC=$?
assert_eq "$DL_RC" "3" "§29r a comma inside a value does not truncate it — the same-stamp disagreement is a CONFLICT"
assert_not_contains "$DL_OUT" "differ only in carry provenance" "§29r ...not reported as a carry-provenance match"
# §29s — `1e999` is legal JSON (both parsers take it) and parses to INFINITY, which sorts above every real
# stamp. `_field_json`'s isfinite guard is the only thing that makes it unreadable; without it such a
# record is published and becomes the ordering authority for its key (round 9: the guard was unpinned).
mini_fixture inf
IN_BOX="$MINI_ROOT/box"; mkdir -p "$IN_BOX"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":1e999}\n' \
  "$HEAD_A" > "$IN_BOX/$NEST_KEY.json"
if python3 -c 'import json,sys,math;print(math.isinf(json.load(open(sys.argv[1]))["reviewed_at"]))' "$IN_BOX/$NEST_KEY.json" 2>/dev/null | grep -qx True; then
  ok "§29s (premise) the reader parses the fixture's stamp to INFINITY (it is legal JSON)"
else
  bad "§29s (premise) the fixture does not carry an infinite stamp"
fi
IN_OUT="$(mini_rs "$IN_BOX" push)"; IN_RC=$?
assert_not_contains "$IN_OUT" "pushed $NEST_KEY" "§29s an INFINITE stamp is unreadable — never published as an ordering authority"
assert_contains "$IN_OUT" "no readable reviewed_at" "§29s ...and the run names the missing stamp"
# §29t — `repo` IS PART OF THE READER'S RULE SET. `extensions/review-enforcer` refuses the whole record
# (reads it as absent) when `repo` is present and fails its charset; `record_usable` tested only
# `head_sha`/`verdict`, so `push` published a record the gate cannot use and `pull` installed it, both at
# rc 0 with `unreadable=0` — and rule 2 forbids deleting it, so the bytes are permanent fleet-wide
# (round 10). The regex is the one `record-review.sh` enforces at mint time.
mini_fixture repochars
RC_BOX="$T/repochars.box"; mkdir -p "$RC_BOX"
# a LEGACY number-keyed filename, so `local_keyed` does not reject it before the usability gate runs
printf '{"pr":441,"head_sha":"%s","verdict":"clean","repo":"a+b/c","reviewed_at":"2026-11-09T00:00:00Z"}\n' \
  "$HEAD_A" > "$RC_BOX/441.json"
if node -e 'const r=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.exit(/^[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+$/.test(r.repo)?0:1)' "$RC_BOX/441.json" 2>/dev/null; then
  bad "§29t (premise) the gate's charset ACCEPTED the fixture repo — the arm would prove nothing"
else
  ok "§29t (premise) the gate's own charset REFUSES the fixture repo"
fi
RC_OUT="$(mini_rs "$RC_BOX" push)"; RC_RC=$?
assert_not_contains "$RC_OUT" "pushed " "§29t a record whose repo the GATE refuses is never published"
assert_contains "$RC_OUT" "not one the fleet's rail can USE" "§29t ...and the refusal names usability"
# §29i — `null` is not a timestamp. The literal text sorts ABOVE every real stamp (`'n' > '2'`), so reading
# it as `null` made a record with no stamp win the ordering instead of being unreadable.
NEST9D="$MINI_ROOT/box9"; mkdir -p "$NEST9D"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":null}\n' \
  "$HEAD_A" > "$NEST9D/$NEST_KEY.json"
N9_OUT="$(mini_rs "$NEST9D" push)"
assert_contains "$N9_OUT" "no readable reviewed_at" '§29i "reviewed_at":null is UNREADABLE, not the literal text null'
assert_not_contains "$N9_OUT" "pushed $NEST_KEY" '§29i ...so it is never published'
# §29p — the SPACED-KEY-ONLY shape: a flat, strictly-valid record whose only occurrence of the key is
# written `"k" :v`. The exact-token scan finds nothing, so an ordering that tests the exact token FIRST
# returns empty and the whitespace route (which exists for exactly this shape) can never fire — this box
# then cannot publish a record the gate WOULD use, and no peer can materialise it (round 6, measured:
# 180/255 fuzzed separator variants, all of them this class).
NESTED_="$MINI_ROOT/boxe"
# its OWN fixture: `mini_fixture` rebinds the global store, so an arm that shares one with a later arm
# silently reads whichever store was created last (measured: §29p picked up a later arm's POISONED ref).
mini_fixture spaced
NESTED_="$MINI_ROOT/boxe"; mkdir -p "$NESTED_"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo" :"daniel-ospina/agent-infra","reviewed_at" :"2026-11-02T00:00:00Z"}\n' \
  "$HEAD_B" > "$NESTED_/$NEST_KEY.json"
if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["repo"], d["reviewed_at"])' "$NESTED_/$NEST_KEY.json" 2>/dev/null | grep -q 'daniel-ospina/agent-infra 2026-11-02'; then
  ok "§29p (premise) the reader accepts the spaced-key record and sees its fields"
else
  bad "§29p (premise) the fixture is not the shape the arm needs"
fi
NE_OUT="$(mini_rs "$NESTED_" push)"
assert_contains "$NE_OUT" "pushed $NEST_KEY" "§29p a shared, strictly-valid record with spaced keys IS published (no false block)"
assert_not_contains "$NE_OUT" "no readable reviewed_at" "§29p ...and is not read as an empty stamp"
# §29m — NOTHING MAY BE PUBLISHED THAT THE READER REFUSES. Pull-side usability was gated from the start;
# push-side was not, so a SINGLE-LINE record the strict parser rejects was published to the SHARED store at
# rc 0 with `unreadable=0` — and every peer then sat at exit 4 for ever (one record per PR, no delete path,
# round 5). A trailing comma is the shape: the fast path reads every field, `json.load` refuses the file.
NESTAD="$MINI_ROOT/boxa"; mkdir -p "$NESTAD"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-30T00:00:00Z",}\n' \
  "$HEAD_A" > "$NESTAD/$NEST_KEY.json"
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$NESTAD/$NEST_KEY.json" 2>/dev/null; then
  bad "§29m (premise) the fixture parses — it must NOT (a trailing comma)"
else
  ok "§29m (premise) the strict reader REFUSES the fixture"
fi
NA_OUT="$(mini_rs "$NESTAD" push)"
assert_not_contains "$NA_OUT" "pushed $NEST_KEY" "§29m a record the strict reader refuses is NOT published to the shared store"
assert_contains "$NA_OUT" "not one the fleet's rail can USE" "§29m ...and the refusal NAMES usability, not the ordering"
# ...and the same for a VALID record this box's rail cannot use (no 40-hex head_sha).
NESTBD="$MINI_ROOT/boxb"; mkdir -p "$NESTBD"
printf '{"pr":2374,"head_sha":"nope","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-31T00:00:00Z"}\n' \
  > "$NESTBD/$NEST_KEY.json"
NB_OUT="$(mini_rs "$NESTBD" push)"
assert_not_contains "$NB_OUT" "pushed $NEST_KEY" "§29m a valid-json record with no usable head_sha is NOT published either"

# ═══ 30. the compare+write lock: reclaimed in every dead-holder shape, bounded in every arm ══
# Review findings P2 (two of them) on PR #3894 — `git grep 'reg_lock' -- scripts/*.test.sh` had NO
# match, so `reg_lock()` could be replaced with `return 0` and the suite stayed green (measured,
# mutation run), and neither measured defect was caught. Each arm below is one measured shape:
#   (a) a LIVE holder is never stolen          (b) a LIVE-but-EPERM holder is not "dead"
#   (c) no pid file at all                     (d) a pid RECYCLED by an unrelated process
#   (e) a lock that cannot be REMOVED must still EXIT (the first cut hot-spun for ever)
# The store holds exactly ONE key: each armed run pays the ~5 s serialisation bound per key.
echo "── §30 the compare+write lock is reclaimed in every dead-holder shape, and bounded in every arm"
mini_fixture lock
LCK_KEY="$KEY"
LOCK_SEED="$MINI_ROOT/seed"; mkdir -p "$LOCK_SEED"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-20T10:00:00Z"}\n' \
  "$HEAD_A" > "$LOCK_SEED/$LCK_KEY.json"
mini_rs "$LOCK_SEED" push >/dev/null 2>&1
LKD="$MINI_ROOT/box"; mkdir -p "$LKD"
lock_reset() { rm -rf "$LKD/.registry-sync.lock"; rm -f "$LKD/$LCK_KEY.json"; }
# (a) a live holder
lock_reset
mkdir -p "$LKD/.registry-sync.lock"; printf '%s\n' "$$" > "$LKD/.registry-sync.lock/pid"
LA_OUT="$(mini_rs "$LKD" pull)"; LA_RC=$?
assert_eq "$LA_RC" "1" "§30a a lock held by a LIVE pid REFUSES the pull (exit 1, nothing written)"
assert_contains "$LA_OUT" "could not serialise" "§30a ...and NAMES the lock as the reason"
assert_absent "$LKD" "$LKD/$LCK_KEY.json" "§30a ...and wrote no record without it"
# (b) a live holder this user cannot signal — `kill -0` reports EPERM as FAILURE, so the first cut
# read it as dead and STOLE the lock, reopening the very race the lock exists to close.
lock_reset
if kill -0 1 2>/dev/null; then
  ok "§30b (premise NOT reachable) this suite runs as root, where no pid is unsignalable — recorded as an explicit skip, not a silent pass"
else
  mkdir -p "$LKD/.registry-sync.lock"; printf '1\n' > "$LKD/.registry-sync.lock/pid"
  LB_OUT="$(mini_rs "$LKD" pull)"; LB_RC=$?
  assert_eq "$LB_RC" "1" "§30b a lock whose LIVE holder is unsignalable (EPERM) is NOT stolen (exit 1)"
  if [ -d "$LKD/.registry-sync.lock" ]; then ok "§30b ...the live holder's lock dir is still there"; else bad "§30b ...the live holder's lock was STOLEN (EPERM read as dead)"; fi
  assert_contains "$LB_OUT" "could not serialise" "§30b ...and the run says it could not serialise rather than writing"
  assert_absent "$LKD" "$LKD/$LCK_KEY.json" "§30b ...and no record was written under a stolen lock"
fi
# (c) NO pid file — the process killed between `mkdir` and the pid write. The first cut's predicate
# (`[ -n "$pid" ] && ! kill -0 …`) could never match this, so ONE kill wedged every later pull for
# ever: every changed record skipped, `union` exit 1, until a human removed the directory.
lock_reset
mkdir -p "$LKD/.registry-sync.lock"
touch -t 202001010000 "$LKD/.registry-sync.lock"
LC_OUT="$(mini_rs "$LKD" pull)"; LC_RC=$?
assert_eq "$LC_RC" "0" "§30c a lock dir with NO pid file is RECLAIMED (one kill must not wedge the pull for ever)"
assert_contains "$LC_OUT" "no usable pid" "§30c ...and the reclaim is NAMED after the real cause"
if [ -f "$LKD/$LCK_KEY.json" ]; then ok "§30c ...and the pull then did its work"; else bad "§30c ...the pull skipped the record after reclaiming"; fi
# (d) a pid the OS RECYCLED onto an unrelated live process: liveness cannot tell, so the lock is also
# reclaimed past LOCK_STALE_MAX — no sync run can hold it that long (every network op is bounded).
lock_reset
mkdir -p "$LKD/.registry-sync.lock"; printf '%s\n' "$$" > "$LKD/.registry-sync.lock/pid"
touch -t 202001010000 "$LKD/.registry-sync.lock"
LD_OUT="$(mini_rs "$LKD" pull)"; LD_RC=$?
assert_eq "$LD_RC" "0" "§30d a lock whose pid was RECYCLED onto a live process is reclaimed past LOCK_STALE_MAX"
assert_contains "$LD_OUT" "longer than any sync run holds it" "§30d ...named as a stale lock, not as a live holder"
if [ -f "$LKD/$LCK_KEY.json" ]; then ok "§30d ...and the pull then did its work"; else bad "§30d ...the pull skipped the record after reclaiming"; fi
# (e) a registry this user can neither write nor rename inside (a root-owned registry dir in a shared
# install). Every acquisition attempt fails, so the bound — not the filesystem — has to end the run: the
# first cut `continue`d on a failed reclaim without sleeping or incrementing and hot-spun with NO bound
# inside atomic-land.sh's pre-sync (measured: 410 reclaim warnings in 4 s, never exits).
# NOTE the shape: a stale lock dir in a registry we CAN write is no longer a wedge at all — the reclaim
# claims it by `mv` (atomic, and it frees the LOCK NAME) and only the debris may be undeletable. The
# arm that still has to be bounded is the one where even `mkdir`/`mv` are refused.
lock_reset
if [ "$(id -u 2>/dev/null || echo 0)" -eq 0 ] || { chmod 500 "$LKD" 2>/dev/null; mkdir "$LKD/.lockprobe" 2>/dev/null; }; then
  # premise NOT established: root ignores the mode bits (and the probe just proved it)
  rmdir "$LKD/.lockprobe" 2>/dev/null || :; chmod 700 "$LKD" 2>/dev/null || :
  ok "§30e (premise NOT reachable) this suite runs as root, where a mode-500 registry is still writable — recorded as an explicit skip, not a silent pass"
else
  run_bounded 60 bash "$SYNC" pull --repo "$MINI_STORE" --dir "$LKD" --remote origin --timeout 30
  EE_OUT="$RB_OUT"; EE_RC="$RB_RC"; EE_TO="$RB_TIMED_OUT"
  assert_eq "$EE_TO" "0" "§30e a registry that cannot be written still EXITS within the bound (no unbounded hot spin)"
  assert_eq "$EE_RC" "1" "§30e ...and it exits 1 (fail closed) instead of writing without the lock"
  assert_contains "$EE_OUT" "could not serialise" "§30e ...naming the lock rather than blaming the store"
  chmod 700 "$LKD" 2>/dev/null || :
fi
# (f) the counterpart the ownership-checked release needs: a run that DID take the lock must still free
# it. `reg_unlock` now removes only a lock whose `pid` is its own, so a wrong comparison (or a release
# that skips removal) would leave the lock behind on every pull — and the next run would then see a
# dead-pid lock. Asserted on the run that just reclaimed and pulled — BEFORE any reset, or it would be
# vacuous (round 8: a `lock_reset` here deleted the very directory the assertion looks for, so it could
# only ever print ✅).
if [ -d "$LKD/.registry-sync.lock" ]; then
  bad "§30f a successful pull RELEASED its lock (a leftover would make the next run wait for a dead holder)"
else
  ok "§30f a successful pull RELEASED its lock (the ownership check still matches our own pid)"
fi
case "$(command ls -d "$LKD"/.registry-sync.lock.stale.* 2>/dev/null)" in
  '') ok "§30f ...and left no .stale.<pid> debris when the claim could delete what it claimed" ;;
  *) bad "§30f ...left reclaim debris behind: $(command ls -d "$LKD"/.registry-sync.lock.stale.* 2>/dev/null)" ;;
esac
# (g) RELEASE ONLY WHAT WE STILL OWN. The ceiling arm can reclaim a lock that still names a LIVE pid (a
# frozen holder), so that holder reaches `reg_unlock` after losing it — and an unconditional removal
# then deletes the NEW holder's lock, letting a third run in. Pinned by interposing a PEER RECLAIM at
# the exact moment of release: a `cat` shim on PATH swaps in a foreign lock the first time the script
# reads its own pid file, so the release finds a pid that is not its own.
lock_reset
SHIM_G="$T/shim-g"; mkdir -p "$SHIM_G"; : > "$T/g.fired"
REAL_CAT="$(command -v cat)"
cat > "$SHIM_G/cat" <<EOS
#!/bin/sh
case "\$1" in
  */.registry-sync.lock/pid)
    if [ ! -s "$T/g.fired" ]; then
      printf 'x' > "$T/g.fired"
      lockdir="\$(dirname "\$1")"
      rm -rf "\$lockdir"                       # a peer reclaimed our lock...
      mkdir -p "\$lockdir"                     # ...and a NEW holder owns the same name
      printf '999999\\n' > "\$lockdir/pid"
      printf '999999\\n'; exit 0
    fi ;;
esac
exec "$REAL_CAT" "\$@"
EOS
chmod +x "$SHIM_G/cat"
G_OUT="$(PATH="$SHIM_G:$PATH" bash "$SYNC" pull --repo "$MINI_STORE" --dir "$LKD" --remote origin --timeout 30 2>&1)"
if [ -f "$LKD/.registry-sync.lock/pid" ] && [ "$(command cat "$LKD/.registry-sync.lock/pid")" = "999999" ]; then
  ok "§30g a release DELETED only its own lock — the new holder's lock survived"
else
  bad "§30g the release deleted a lock it no longer owned (the new holder's lock is gone)"
fi
if [ -s "$T/g.fired" ]; then ok "§30g (premise) the foreign reclaim WAS interposed at release"; else bad "§30g (premise) the shim never fired — the arm proves nothing"; fi
rm -rf "$LKD/.registry-sync.lock"; lock_reset
# (h) THE CEILING MUST OUTLIVE THE RUN'S OWN BOUND. `--timeout` is an operator knob, so a fixed 300 s
# would reclaim a legitimate `--timeout 600` run inside its own critical section. Same lock, same age
# (400 s), two bounds: it must be KEPT at 600 (ceiling 1200) and RECLAIMED at 30 (ceiling 300).
OLD400="$(python3 -c 'import time;print(time.strftime("%Y%m%d%H%M.%S", time.localtime(time.time()-400)))')"
lock_reset
mkdir -p "$LKD/.registry-sync.lock"; printf '%s\n' "$$" > "$LKD/.registry-sync.lock/pid"
touch -t "$OLD400" "$LKD/.registry-sync.lock"
H60_OUT="$(bash "$SYNC" pull --repo "$MINI_STORE" --dir "$LKD" --remote origin --timeout 600 2>&1)"; H60_RC=$?
assert_eq "$H60_RC" "1" "§30h a 400s-old lock naming a LIVE pid is KEPT at --timeout 600 (ceiling 1200)"
assert_contains "$H60_OUT" "could not serialise" "§30h ...and the refusal names the lock"
H30_OUT="$(bash "$SYNC" pull --repo "$MINI_STORE" --dir "$LKD" --remote origin --timeout 30 2>&1)"; H30_RC=$?
assert_eq "$H30_RC" "0" "§30h ...and the SAME lock is reclaimed at --timeout 30 (ceiling 300), so the arm is not a no-op"
assert_contains "$H30_OUT" "longer than any sync run holds it" "§30h ...named as past the ceiling"
lock_reset
# (i) THE CLAIM IS ATOMIC, AND A LOCK WE DID NOT JUDGE IS NEVER DELETED. A peer can re-create the lock
# between the decision and the claim (review round 2, measured: two holders overlapped 2.1 s, and the
# second reclaimer's `rm -rf` deleted the first one's LIVE lock). Pinned by re-creating the lock
# underneath the claim: a `mv` shim puts a FOREIGN lock at the lock name just before the real rename,
# so the claim moves a lock it did not judge. It must be put BACK, not deleted.
SHIM_I="$T/shim-i"; mkdir -p "$SHIM_I"; : > "$T/i.fired"
REAL_MV="$(command -v mv)"
IPID="$$"   # a pid that IS alive (this suite), so the re-created lock is never legitimately reclaimable
cat > "$SHIM_I/mv" <<EOS
#!/bin/sh
case "\$1" in
  */.registry-sync.lock)
    case "\$2" in
      */.registry-sync.lock.stale.*)
        if [ ! -s "$T/i.fired" ]; then
          printf 'x' > "$T/i.fired"
          rm -rf "\$1"                                    # a peer won a reclaim...
          mkdir -p "\$1"; printf '%s\\n' $IPID > "\$1/pid"  # ...and a LIVE holder re-created it
        fi ;;
    esac ;;
esac
exec "$REAL_MV" "\$@"
EOS
chmod +x "$SHIM_I/mv"
lock_reset
mkdir -p "$LKD/.registry-sync.lock"
touch -t 202001010000 "$LKD/.registry-sync.lock"
I_OUT="$(PATH="$SHIM_I:$PATH" bash "$SYNC" pull --repo "$MINI_STORE" --dir "$LKD" --remote origin --timeout 30 2>&1)"; I_RC=$?
if [ -s "$T/i.fired" ]; then ok "§30i (premise) the re-create-under-the-claim WAS interposed"; else bad "§30i (premise) the claim never renamed the lock, so atomicity is unproven (a decide-then-rm reclaim has no claim to interpose on)"; fi
if [ -f "$LKD/.registry-sync.lock/pid" ] && [ "$(command cat "$LKD/.registry-sync.lock/pid")" = "$IPID" ]; then
  ok "§30i a claim that moved a lock it did NOT judge put it back instead of deleting a live lock"
else
  bad "§30i the claim DELETED a lock it never judged (the live holder's lock is gone)"
fi
assert_eq "$I_RC" "1" "§30i ...and that run fails closed rather than writing without the lock"
rm -rf "$LKD/.registry-sync.lock"; lock_reset
# (j) A FRESH PID-LESS LOCK IS A LIVE ACQUIRER, NOT AN ABANDONED LOCK. §30c uses a 2020-dated lock, so on
# its own it cannot tell "reclaim a STALE pid-less lock" from "reclaim a pid-less lock at ANY age" —
# the latter is round 2's measured steal of an acquirer descheduled between `mkdir` and the pid write
# (round 4: dropping the age gate left the suite green). Only elapsed time may break the ambiguous shape.
lock_reset
mkdir -p "$LKD/.registry-sync.lock"     # no pid file, and NO touch: this lock is seconds old
J_AGE="$(python3 -c 'import os,sys,time; print(int(time.time()-os.stat(sys.argv[1]).st_mtime))' "$LKD/.registry-sync.lock" 2>/dev/null)"
case "$J_AGE" in
  0|1) ok "§30j (premise) the pid-less lock is YOUNGER than the grace (${J_AGE}s), so the ceiling is the only arm that could reclaim it" ;;
  *) bad "§30j (premise) the fixture is not fresh (${J_AGE}s) — the arm would not discriminate" ;;
esac
J_OUT="$(mini_rs "$LKD" pull)"; J_RC=$?
assert_eq "$J_RC" "1" "§30j a FRESH pid-less lock is NOT reclaimed (it is a live acquirer's mkdir-to-pid window)"
assert_contains "$J_OUT" "could not serialise" "§30j ...and the run refuses instead of writing"
if [ -d "$LKD/.registry-sync.lock" ]; then ok "§30j ...and the acquirer's lock dir is still there"; else bad "§30j ...the fresh pid-less lock was STOLEN"; fi
assert_absent "$LKD" "$LKD/$LCK_KEY.json" "§30j ...and nothing was written without the lock"
rm -rf "$LKD/.registry-sync.lock"
# (k) A PROBE THAT CANNOT ANSWER IS NOT EVIDENCE. `ps -p <missing>` and `ps -p <live-but-invisible>` are
# byte-identical, so a `ps` that cannot SEE the pid must not be read as "the holder is dead" — that is
# round 1's EPERM defect moved from permission to visibility, and it was measured stealing a LIVE
# holder's lock on the first failed probe (round 4). Pinned with a `ps` that can never answer; where
# /proc exists it PROVES the holder is alive, and where it does not the answer is "unknown", which
# routes to the ceiling instead of the 2 s grace. Either way the lock is kept.
SHIM_K="$T/shim-k"; mkdir -p "$SHIM_K"; : > "$T/k.called"
printf '#!/bin/sh\nprintf x >> "%s"\nexit 1\n' "$T/k.called" > "$SHIM_K/ps"; chmod +x "$SHIM_K/ps"
lock_reset
mkdir -p "$LKD/.registry-sync.lock"; printf '1\n' > "$LKD/.registry-sync.lock/pid"
# 60 s: past the 2 s grace (so a `gone` verdict WOULD reclaim it — that is the mutation) and far below the
# 1200 s ceiling at `--timeout 600`, so the ceiling arm cannot explain a pass.
AGE60="$(python3 -c 'import time;print(time.strftime("%Y%m%d%H%M.%S", time.localtime(time.time()-60)))')"
touch -t "$AGE60" "$LKD/.registry-sync.lock"
K_OUT="$(PATH="$SHIM_K:$PATH" bash "$SYNC" pull --repo "$MINI_STORE" --dir "$LKD" --remote origin --timeout 600 2>&1)"; K_RC=$?
assert_eq "$K_RC" "1" "§30k a lock whose holder a BLIND ps cannot see is NOT reclaimed (the probe cannot answer)"
if [ -s "$T/k.called" ]; then ok "§30k (premise) the blind ps WAS consulted (the arm is not vacuous)"; else bad "§30k (premise) the ps shim never ran — the arm proves nothing"; fi
if [ -d "$LKD/.registry-sync.lock" ]; then ok "§30k ...the live holder's lock is still there"; else bad "§30k ...the lock was STOLEN on an unanswered probe"; fi
assert_contains "$K_OUT" "could not serialise" "§30k ...and the run fails closed rather than writing"
rm -rf "$LKD/.registry-sync.lock"; lock_reset
# (l) AN UNDATEABLE LOCK IS NEVER RECLAIMED. Every reclaim arm keys on elapsed time, so when no `stat` can
# answer there is NO evidence the holder is gone — stealing it would reopen the compare+write race on the
# strength of a failed measurement (round 5: the guard could be inverted with the suite green). Pinned
# with a `stat` that can never answer.
SHIM_L="$T/shim-l"; mkdir -p "$SHIM_L"; : > "$T/l.called"
printf '#!/bin/sh\nprintf x >> "%s"\nexit 1\n' "$T/l.called" > "$SHIM_L/stat"; chmod +x "$SHIM_L/stat"
lock_reset
mkdir -p "$LKD/.registry-sync.lock"; printf '999999\n' > "$LKD/.registry-sync.lock/pid"
L_OUT="$(PATH="$SHIM_L:$PATH" bash "$SYNC" pull --repo "$MINI_STORE" --dir "$LKD" --remote origin --timeout 30 2>&1)"; L_RC=$?
assert_eq "$L_RC" "1" '§30l a lock no stat can date is NOT reclaimed (a failed measurement is not evidence)'
if [ -s "$T/l.called" ]; then ok "§30l (premise) the failing stat WAS consulted (the lock really was undateable)"; else bad "§30l (premise) the stat shim never ran — the arm proves nothing"; fi
if [ -d "$LKD/.registry-sync.lock" ]; then ok "§30l ...the lock is still there"; else bad "§30l ...the undateable lock was STOLEN"; fi
assert_absent "$LKD" "$LKD/$LCK_KEY.json" "§30l ...and nothing was written without it"
rm -rf "$LKD/.registry-sync.lock"; lock_reset
# (n) THE PID-LESS IDENTITY IS THE AGE, NOT THE PID. `"" = ""` matched a RE-CREATED pid-less lock — a
# live acquirer in its `mkdir`→pid-write window — so the claim DELETED a live lock and this run then
# entered the critical section beside it (round 7, reproduced with the same interposition §30i uses, only
# with a pid-less foreign lock). `mv` preserves mtime, so the judged lock still reads its old age while a
# fresh one reads ~0 s: the re-created lock must be RESTORED.
SHIM_N="$T/shim-n"; mkdir -p "$SHIM_N"; : > "$T/n.fired"
REAL_MV_N="$(command -v mv)"
cat > "$SHIM_N/mv" <<EOS
#!/bin/sh
case "\$1" in
  */.registry-sync.lock)
    case "\$2" in
      */.registry-sync.lock.stale.*)
        if [ ! -s "$T/n.fired" ]; then
          printf 'x' > "$T/n.fired"
          rm -rf "\$1"              # a live acquirer won the name...
          mkdir -p "\$1"            # ...and has NOT written its pid yet (its mkdir→pid window)
        fi ;;
    esac ;;
esac
exec "$REAL_MV_N" "\$@"
EOS
chmod +x "$SHIM_N/mv"
lock_reset
mkdir -p "$LKD/.registry-sync.lock"
touch -t 202001010000 "$LKD/.registry-sync.lock"
N_OUT="$(PATH="$SHIM_N:$PATH" bash "$SYNC" pull --repo "$MINI_STORE" --dir "$LKD" --remote origin --timeout 30 2>&1)"; N_RC=$?
if [ -s "$T/n.fired" ]; then ok "§30n (premise) the pid-less re-create WAS interposed under the claim"; else bad "§30n (premise) the claim never renamed the lock — the arm proves nothing"; fi
if [ -d "$LKD/.registry-sync.lock" ] && [ ! -f "$LKD/.registry-sync.lock/pid" ]; then
  ok "§30n a claim that moved a re-created PID-LESS lock put it back (the acquirer's lock survived)"
else
  bad "§30n the claim DELETED a live acquirer's pid-less lock (an empty pid is not an identity)"
fi
assert_eq "$N_RC" "1" "§30n ...and that run fails closed rather than writing beside the acquirer"
rm -rf "$LKD/.registry-sync.lock" "$LKD"/.registry-sync.lock.stale.*; lock_reset
# (o) THE BOUND IS PER RUN, NOT PER KEY. `pull_one` takes the lock once per record, so a lock this box can
# NEVER acquire cost the ~5 s bound PER KEY — measured 18 s for a 3-key registry, i.e. hours at the 4,027
# size this file cites, inside atomic-land.sh's pre-sync (round 8). One failure is memoised for the run.
mini_fixture lockmany
LM_SEED="$MINI_ROOT/seed"; mkdir -p "$LM_SEED"
for LM_PR in 901 902 903; do
  printf '{"pr":%s,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"acme/widget","reviewed_at":"2026-10-20T00:00:00Z"}\n' \
    "$LM_PR" "$HEAD_A" > "$LM_SEED/acme-widget-$LM_PR.json"
done
mini_rs "$LM_SEED" push >/dev/null 2>&1
LM_BOX="$MINI_ROOT/box"; mkdir -p "$LM_BOX"
mkdir -p "$LM_BOX/.registry-sync.lock"; printf '1\n' > "$LM_BOX/.registry-sync.lock/pid"
O_T0="$(python3 -c 'import time;print(time.time())')"
run_bounded 40 bash "$SYNC" pull --repo "$MINI_STORE" --dir "$LM_BOX" --remote origin --timeout 30
O_TO="$RB_TIMED_OUT"; O_OUT="$RB_OUT"; O_RC="$RB_RC"
O_SECS="$(python3 -c "import time;print(int(time.time()-$O_T0))")"
# PREMISE: the store really holds 3 keys (so the un-memoised cost WOULD be 3 x the bound) and the run
# really reached the lock (so the wait, not something else, is what the elapsed time measures).
if [ "$(git -C "$MINI_STORE" ls-remote --refs origin 'refs/reviews/*' 2>/dev/null | command wc -l | tr -d ' ')" = "3" ]; then
  ok "§30o (premise) the store holds 3 keys, so the per-key cost would be 3 x the bound"
else
  bad "§30o (premise) the store does not hold 3 keys — the per-key cost would not be exercised"
fi
assert_contains "$O_OUT" "could not serialise" "§30o (premise) the run DID reach the lock"
assert_eq "$O_TO" "0" "§30o a permanently unacquirable lock does not make the run unbounded"
assert_eq "$O_RC" "1" "§30o ...it still fails closed"
# 3 keys x the ~5 s bound would be ~15-18 s (measured); the memoised run pays it ONCE.
if [ "$O_SECS" -lt 12 ]; then
  ok "§30o ...and the ~5 s wait is paid ONCE for the run (${O_SECS}s for 3 keys), not once per key"
else
  bad "§30o ...the lock wait was paid per key (${O_SECS}s for 3 keys), so the run is O(keys) x 5s"
fi
rm -rf "$LM_BOX/.registry-sync.lock"

# §30p — AND THE MESSAGE MUST BE TRUE. §30o fixes the COST of a permanently unacquirable lock; it left the
# DIAGNOSIS wrong, and the diagnosis is what the operator acts on: every key reported "another run holds"
# a lock that nobody held and that this user could not create, and the summary advised "Re-run to retry" —
# a re-run meets the SAME unwritable registry (the #2349 class: naming the wrong side sends the operator
# down a path that fails identically). The shape is the one §30e's own premise names: a lock left in a
# registry this user cannot write (a root-owned lock from a `sudo` run in a shared install), so `mkdir`
# AND `claim_stale`'s `mv` are both refused and the name never frees. Behaviour is asserted UNCHANGED
# alongside the wording, so this arm cannot be satisfied by weakening the memoisation §30o pins.
mini_fixture lockperm
LP_SEED="$MINI_ROOT/seed"; mkdir -p "$LP_SEED"
for LP_PR in 921 922 923; do
  printf '{"pr":%s,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"acme/widget","reviewed_at":"2026-10-20T00:00:00Z"}\n' \
    "$LP_PR" "$HEAD_A" > "$LP_SEED/acme-widget-$LP_PR.json"
done
mini_rs "$LP_SEED" push >/dev/null 2>&1
LP_BOX="$MINI_ROOT/box"; mkdir -p "$LP_BOX"
mkdir -p "$LP_BOX/.registry-sync.lock"; printf '1\n' > "$LP_BOX/.registry-sync.lock/pid"
if [ "$(id -u 2>/dev/null || echo 0)" -eq 0 ] || { chmod 500 "$LP_BOX" 2>/dev/null; mkdir "$LP_BOX/.lockprobe" 2>/dev/null; }; then
  rmdir "$LP_BOX/.lockprobe" 2>/dev/null || :; chmod 700 "$LP_BOX" 2>/dev/null || :
  ok "§30p (premise NOT reachable) this suite runs as root, where a mode-500 registry is still writable — recorded as an explicit skip, not a silent pass"
else
  run_bounded 40 bash "$SYNC" pull --repo "$MINI_STORE" --dir "$LP_BOX" --remote origin --timeout 30
  P_TO="$RB_TIMED_OUT"; P_OUT="$RB_OUT"; P_RC="$RB_RC"
  chmod 700 "$LP_BOX" 2>/dev/null || :
  assert_eq "$P_TO" "0" "§30p a registry that can never host a lock still TERMINATES"
  assert_eq "$P_RC" "1" "§30p ...and still fails closed (rc 1)"
  assert_contains "$P_OUT" "can be neither created nor removed here" "§30p ...naming the REAL cause instead of an invisible permission"
  assert_not_contains "$P_OUT" "another run holds" "§30p ...and NOT claiming a peer holds a lock nobody holds"
  assert_contains "$P_OUT" "failed=3" "§30p ...still counting every key (§30o's memoisation is not weakened)"
  assert_contains "$P_OUT" "neither create nor remove" "§30p ...and the summary names the permission as the remedy"
  assert_not_contains "$P_OUT" "re-run to retry (nothing was deleted, and no record was overwritten with an older one)" "§30p ...rather than a re-run that meets the same directory"
fi
# (q) AN OUTSTANDING PUT-BACK BLOCKS ENTRY. The round-8 fix remembered an un-restorable claimed directory
# (`PENDING_STALE`) but still tried `mkdir` first, so once the third acquirer released the name the run
# ACQUIRED with a live holder's lock still in debris and wrote beside it (round 9, measured 3 of 4 runs).
# Pinned by replaying exactly that: an `mv` shim re-creates a foreign lock under the claim (so the
# put-back fails), and a `sleep` shim then FREES the name — mimicking the third acquirer finishing — so a
# run without the entry gate would acquire and write, while a gated run restores first, finds the name
# taken by a FRESH lock, and refuses.
SHIM_P="$T/shim-p"; mkdir -p "$SHIM_P"; : > "$T/p.mv"; : > "$T/p.free"
# its OWN fixture with exactly the ONE key under test: every `mini_fixture` rebinds the global store, so
# an arm that reuses `$LKD`/`$MINI_STORE` can end up pulling a LATER fixture's keys (measured: the run
# converged on someone else's records and reported rc 0 for an unrelated reason).
mini_fixture lockgate
PG_SEED="$MINI_ROOT/seed"; mkdir -p "$PG_SEED"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-20T00:00:00Z"}\n' \
  "$HEAD_A" > "$PG_SEED/$LCK_KEY.json"
mini_rs "$PG_SEED" push >/dev/null 2>&1
LKD="$MINI_ROOT/box"; mkdir -p "$LKD"
lock_reset() { rm -rf "$LKD/.registry-sync.lock"; rm -f "$LKD/$LCK_KEY.json"; }
lock_reset
REAL_MV_P="$(command -v mv)"; REAL_SLEEP_P="$(command -v sleep)"
cat > "$SHIM_P/mv" <<EOS
#!/bin/sh
case "\$1" in
  */.registry-sync.lock)
    case "\$2" in
      */.registry-sync.lock.stale.*)
        if [ ! -s "$T/p.mv" ]; then
          printf 'x' > "$T/p.mv"
          rm -rf "\$1"; mkdir -p "\$1"          # a live acquirer holds the name (fresh, pid-less)...
          "$REAL_MV_P" "\$@"; rc=\$?            # ...so the claim moves a lock it CANNOT have judged
          mkdir -p "\$1"                         # and a third party takes the freed name
          exit \$rc
        fi ;;
    esac ;;
esac
exec "$REAL_MV_P" "\$@"
EOS
cat > "$SHIM_P/sleep" <<EOS
#!/bin/sh
if [ -s "$T/p.mv" ] && [ ! -s "$T/p.free" ]; then
  printf 'x' > "$T/p.free"; rm -rf "$LKD/.registry-sync.lock"   # ...and then releases it
fi
exec "$REAL_SLEEP_P" "\$@"
EOS
chmod +x "$SHIM_P/mv" "$SHIM_P/sleep"
mkdir -p "$LKD/.registry-sync.lock"
touch -t 202001010000 "$LKD/.registry-sync.lock"
P_OUT="$(PATH="$SHIM_P:$PATH" bash "$SYNC" pull --repo "$MINI_STORE" --dir "$LKD" --remote origin --timeout 30 2>&1)"; P_RC=$?
if [ -s "$T/p.mv" ]; then
  ok "§30q (premise) a claim moved a lock it could not have judged (the interleaving happened)"
else
  bad "§30q (premise) no claim was interposed — the arm proves nothing"
fi
assert_contains "$P_OUT" "HELD for restore" "§30q (premise) the put-back really FAILED (a third party held the name)"
assert_absent "$LKD" "$LKD/$LCK_KEY.json" "§30q a run with an OUTSTANDING put-back does not enter the critical section"
assert_eq "$P_RC" "1" "§30q ...and it fails closed"
rm -rf "$LKD/.registry-sync.lock" "$LKD"/.registry-sync.lock.stale.*; lock_reset
# §30m — NOT PINNED, and said so rather than faked. `reg_lock` now refuses to enter the critical section
# when it cannot write its own `pid` (a lock it cannot record itself in is a lock it can never release:
# `reg_unlock` removes only a lock whose pid is ours, so the directory would stay and the pid-less arm
# does not fire until the staleness ceiling). There is no hermetic way to inject that failure through
# the CLI: `umask 0777` is the only lever and it also makes the run's OWN scratch files unreadable
# (measured: `store.tsv: Permission denied`), so it fails for an unrelated reason before reaching the
# lock. The arm is reported as UNPINNED instead of being written vacuously.

# ═══ 31. this box's record is NEWER but UNUSABLE — named, not silently kept for ever ══════
# Review finding P2 on PR #3894: `git grep 'own rail can use' -- scripts/*.test.sh` → no match, and
# deleting the whole arm left the suite at 137/0 (measured, mutation run). The state it names is a
# real dead end — `atomic-land.sh` advertises `pull` as the REMEDY for the refusal a newer-but-unusable
# record causes, and `pull` can never fix it (rule 1 says the newer bytes are not overwritten).
echo '── §31 a newer-but-UNUSABLE local record is NAMED, and pull is not advertised as its cure'
mini_fixture unusable
UN_KEY="$KEY"
UN_SEED="$MINI_ROOT/seed"; mkdir -p "$UN_SEED"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-20T00:00:00Z"}\n' \
  "$HEAD_A" > "$UN_SEED/$UN_KEY.json"
mini_rs "$UN_SEED" push >/dev/null 2>&1
UN_BOX="$MINI_ROOT/box"; mkdir -p "$UN_BOX"
# NEWER stamp, but a head_sha this box's own rail cannot use (not 40 hex) — the shape `read_record`
# refuses with "carries no usable head_sha".
printf '{"pr":2374,"head_sha":"not-a-40-hex-sha","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-25T00:00:00Z"}\n' \
  > "$UN_BOX/$UN_KEY.json"
UN_BEFORE="$(digest "$UN_BOX")"
UN_OUT="$(mini_rs "$UN_BOX" pull)"; UN_RC=$?
assert_eq "$UN_RC" "4" "§31 a newer-but-unusable local record is exit 4, NOT a converged-looking 0"
assert_contains "$UN_OUT" "NOT one its own rail can use" "§31 ...and the run NAMES the state"
assert_contains "$UN_OUT" "cannot repair it" "§31 ...and names the REAL remedy instead of pointing at a verb that cannot help"
assert_eq "$(digest "$UN_BOX")" "$UN_BEFORE" "§31 ...and the newer record is NOT overwritten (rule 1 is not relaxed)"
assert_not_contains "$UN_OUT" "this box is NEWER" "§31 ...and the run does not report a converged-looking keep"
# the rc-4 summary is a FLEET-facing claim, and for THIS arm it would be false: the unusable bytes are on
# this box, not in the store. `atomic-land.sh`'s rc-4 arm repeats the summary's wording, so a wrong
# sentence here sends the operator to the store side — the misdirection this arm exists to remove.
assert_contains "$UN_OUT" "THIS BOX's OWN unusable" "§31 ...and the SUMMARY blames this box's own record, not the store"
assert_not_contains "$UN_OUT" "the store holds records this box cannot use" "§31 ...and does not make the fleet-facing claim about the store"
# §31b — the EQUAL-STAMP arm had no usability test, so this box's own unusable record at the peer's exact
# stamp/head/verdict was KEPT and reported converged at rc 0 with `unreadable=0` — the same dead end one arm
# over from the one §31 names (round 7). Rule 1 is still not relaxed: the bytes are not overwritten.
EQ_BOX="$MINI_ROOT/box-eq"; mkdir -p "$EQ_BOX"
printf '{"pr":2374,"head_sha":"%s","mint":"fresh","verdict":"clean","repo":"daniel-ospina/agent-infra","reviewed_at":"2026-10-20T00:00:00Z",}\n' \
  "$HEAD_A" > "$EQ_BOX/$UN_KEY.json"   # trailing comma: the strict reader REFUSES it
if python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$EQ_BOX/$UN_KEY.json" 2>/dev/null; then
  bad "§31b (premise) the fixture parses — it must NOT (a trailing comma)"
else
  ok "§31b (premise) this box's record is one the strict reader REFUSES"
fi
if grep -q '"reviewed_at":"2026-10-20T00:00:00Z"' "$EQ_BOX/$UN_KEY.json"; then
  ok "§31b (premise) ...and it sits at the PEER's own stamp, so the equal-stamp arm is the one exercised"
else
  bad "§31b (premise) the fixture is not at the peer's stamp — the wrong arm would be exercised"
fi
EQ_BEFORE="$(digest "$EQ_BOX")"
EQ_OUT="$(mini_rs "$EQ_BOX" pull)"; EQ_RC=$?
assert_eq "$EQ_RC" "4" "§31b this box's unusable record at the PEER'S OWN stamp is exit 4, not a converged-looking 0"
assert_contains "$EQ_OUT" "matches the peer's stamp" "§31b ...and the run NAMES the real state"
assert_eq "$(digest "$EQ_BOX")" "$EQ_BEFORE" "§31b ...and it is not overwritten"
assert_not_contains "$EQ_OUT" "differ only in carry provenance" "§31b ...and it is not reported as a carry-provenance match"

# ═══ 10 (continued). nothing above deleted a record either ══════════════════════
for pair in "$BOX1:$KEYA" "$BOX5:$KEYB"; do
  b="${pair%%:*}"; f="${pair##*:}"
  if [ -f "$b/$f.json" ]; then ok "§18–19 $f.json still exists on $(basename "$b")"; else bad "§18–19 $f.json vanished"; fi
done

echo
echo "registry-sync.test.sh: PASS=$PASS FAIL=$FAIL"
SUMMARY_PRINTED=1
[ "$FAIL" -eq 0 ]
