#!/usr/bin/env bash
# registry-sync.sh — replicate the review-record registry across boxes (agent-infra#2374).
#
#   registry-sync.sh pull    [--repo <path>] [--dir <path>] [--remote <name>] [--timeout <n>] [--quiet]
#   registry-sync.sh push    …
#   registry-sync.sh union   …   # pull, then push — the converging verb
#   registry-sync.sh status  …   # counts, plus the records another box has and this one does not
#
# Exit: 0 converged (nothing left to do), 2 usage, 1 cannot run (no store / no remote /
# unwritable registry / a record that could not be moved), 3 CONVERGED WITH DIVERGENCE — at
# least one pair of records shares a `reviewed_at` but disagrees on content, so neither side was
# overwritten (rule 4 below), 4 records were SKIPPED because they could not be read or ordered
# (an unreadable peer ref or stamp, a mis-keyed record) — an unreadable store is not a converged
# one, and 0 must never be reported over records this box could not use.
#
# ── WHY THIS EXISTS ───────────────────────────────────────────────────────────────────────
# `record-review.sh` writes ~/.pi/agent/reviews/<owner>-<repo>-<pr>.json and NOTHING replicated
# that directory. So the merge gate and the rail answer "no review record" for a PR that WAS
# reviewed — on another machine — and a lane that cannot tell "not reviewed" from "not visible
# here" has no correct next action (#2349 measured 142 such blocks on one box; of 104 open PRs
# only 55 were visible from any single box, #2374).
#
# ── WHY THE TRANSPORT IS A GIT REF, AND NOT `cmux` ─────────────────────────────────────────
# #2374's Transport-constraint note measured that `cmux cloud exec` does not forward stdin, so a
# cmux transport pushes a generated script and pulls a base64 tar. Two facts rule it out as the
# replication path, and neither is a preference:
#   1. cmux is NOT on the cells. cloud-cell-bringup.sh's own surface check reports
#      "Linux — cmux-session.ts and launchd are not installed", and a cell is exactly the box
#      that boots blind and needs the records. A pull only the Mac can run cannot satisfy
#      #2374's item 4 ("wired into cell bringup").
#   2. It needs a roster of reachable boxes and the minting box to be AWAKE. Neither exists:
#      there is no box roster in this repo, and a record minted on a box that has since gone
#      dark would be unreachable by construction.
# The one store every box already has, already authenticates to, and can read while a peer is
# offline is the repository. That is not a new idea here — it is the recorded decision the
# cross-box CLAIM registry already runs on (scripts/orchestrator-harness/claims.sh: "The boxes
# already share exactly one durable store: the repository. Creating a ref with `git push` is
# ATOMIC … so `refs/claims/<key>` is a genuine compare-and-swap with no new infrastructure"), and
# its `refs/claims/*` namespace was empirically verified (2026-10-14, both repos) to trigger no
# workflow run, because every `on: push` is filtered to `branches: [main]` or `tags:`. This
# namespace sits outside the branch namespace the same way.
#
# ── WHERE THE RECORDS LIVE ────────────────────────────────────────────────────────────────
# One ref per (repo, PR): `refs/reviews/<owner>-<repo>-<pr>` — the registry FILENAME without its
# `.json`, so ref, file and the gate's key are one identity. The ref points at a commit whose
# tree carries one blob, `record.json`, holding the record's EXACT bytes. One ref per PR (not per
# record, not one shared ref) makes the merge rules safe by construction instead of by locking:
#   * re-pushing the SAME record is a no-op — the ref exists and its content matches;
#   * two boxes pushing DIFFERENT records for one PR contend on one ref, and the loser is a plain
#     non-fast-forward refusal, never a silent overwrite;
#   * the ref name IS the collision detector for rule 4 (equal `reviewed_at`, different bytes).
# The store's OWN listing (`ls-remote`) is the source of truth for what it holds — the local refs a
# fetch leaves behind are a CACHE, and answering from them reported "converged" over a store that
# had received nothing (see `fetch_refs`).
# A single shared ref, or a file on `main`, was rejected: it serialises every box behind a
# read-modify-write race, and a file on main additionally cannot carry a record for a PR that has
# NOT merged yet — which is the only kind of record the merge gate reads.
#
# ── THE FOUR MERGE RULES (#2374 item 2), enforced on BOTH verbs ───────────────────────────
#   1. NEVER overwrite a record with an OLDER `reviewed_at`. Push skips (and says so); pull skips
#      (and says so). The comparison is the record's own timestamp — never file mtime, never
#      "newest written wins".
#   2. NEVER delete a record. There is no delete path: no `--delete`, no `git push :ref`, no `rm`,
#      and the fetch is not `--prune`. A ref or file that existed before a run exists after it.
#   3. NEVER collapse two repos' legacy `<pr>.json` files. A legacy record is synced ONLY when it
#      embeds a `repo` field, and then it is keyed by that repo. A legacy record with no repo
#      field is LEFT ALONE and counted `unkeyed`: writing it under a qualified name would invent
#      an ownership the file never claimed, which is precisely the #426 cross-repo collision.
#   4. A record that DISAGREES on the same `reviewed_at` is REPORTED, never silently overwritten.
#      Neither side wins: the local file stays byte-identical, a `CONFLICT` line names both heads,
#      and the verb exits 3. What counts as a DISAGREEMENT is the VERDICT (and, for two non-carries,
#      the head): two records that agree on both and differ only in carry `carried_from` are the
#      same revision recorded twice, and are not a conflict (see `same_stamp_relation`). A carry
#      whose `carried_from` names neither side's head is still reported — the ordering is genuinely
#      unknown there, and guessing is what this file exists not to do.
#
# ── IDEMPOTENCE (#2374 item 3) ────────────────────────────────────────────────────────────
# A second run writes nothing, pushes nothing and reports zero work: identical content is compared
# byte-for-byte and skipped BEFORE any write. `status` prints `hash=`, a digest over (name,
# content) pairs, so "running it twice changed nothing" is an assertion rather than a claim.
#
# ── WHAT THIS DOES NOT DO ────────────────────────────────────────────────────────────────
# * It decides nothing about a review. It moves bytes between registries; the gate's
#   head/evidence/verdict rules are untouched, and a materialised record is one that the minting
#   box already recorded — with its original `reviewed_at`, `head_sha`, `mint` and `evidence`.
# * It does not keep a per-PR history. The registry holds ONE record per PR (that is the reader's
#   contract: review-enforcer and the rail read one file per PR), so the ref holds the newest; an
#   older record stays in the registry of the box that wrote it and in gate-events.jsonl. A
#   growing chain of refs per PR was rejected as storage and fetch cost for data no reader reads.
# * It never edits or renames a legacy file.
# * It keeps no per-box cache of what it has already pushed. A cache would make a converged run
#   cheap, and it was rejected: a cache that goes stale silently SKIPS a newer record, which is
#   the one failure this file exists to prevent. The cost is paid where it is affordable — a
#   landing, which already waits minutes — and it is one fetch plus a per-record comparison.
#
# ── WHERE IT RUNS ───────────────────────────────────────────────────────────────────────
# `atomic-land.sh` runs `union` before it reads the review record (both directions, at the one
# point every landing passes through), and `cloud-cell-bringup.sh` runs it so a freshly booted
# cell starts with the records that already exist instead of with none. `push` and `pull` are
# also operators' verbs: `status` first to see what is missing here, then `pull`.
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

VERB="${1:-}"
case "$VERB" in
  pull|push|union|status) shift ;;
  -h|--help|"") sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; exit 2 ;;
  *) printf "registry-sync.sh: unknown verb '%s' — usage: registry-sync.sh <pull|push|union|status> [--repo <path>] [--dir <path>] [--remote <name>] [--timeout <n>] [--quiet]\n" "$VERB" >&2; exit 2 ;;
esac

STORE_ARG=""
REG_DIR="${REGISTRY_SYNC_DIR:-$HOME/.pi/agent/reviews}"
REMOTE="${REGISTRY_SYNC_REMOTE:-origin}"
QUIET=0
MAX_WAIT="${REGISTRY_SYNC_TIMEOUT:-60}"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo)    STORE_ARG="${2:-}"; [ -n "$STORE_ARG" ] || { echo "registry-sync.sh: --repo needs a path" >&2; exit 2; }; shift 2 ;;
    --dir)     REG_DIR="${2:-}";   [ -n "$REG_DIR" ]   || { echo "registry-sync.sh: --dir needs a path" >&2; exit 2; }; shift 2 ;;
    --remote)  REMOTE="${2:-}";    [ -n "$REMOTE" ]    || { echo "registry-sync.sh: --remote needs a name" >&2; exit 2; }; shift 2 ;;
    --timeout)
      MAX_WAIT="${2:-}"
      case "$MAX_WAIT" in
        ''|*[!0-9]*) echo "registry-sync.sh: --timeout needs a POSITIVE integer number of seconds (got '${MAX_WAIT}')" >&2; exit 2 ;;
      esac
      [ "$MAX_WAIT" -gt 0 ] 2>/dev/null || { echo "registry-sync.sh: --timeout must be > 0 (got '${MAX_WAIT}')" >&2; exit 2; }
      shift 2 ;;
    --quiet)   QUIET=1; shift ;;
    *) echo "registry-sync.sh: unknown option '$1'" >&2; exit 2 ;;
  esac
done

log_line()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
warn() { printf '%s\n' "$*" >&2; }

# ── bounded git ───────────────────────────────────────────────────────────────────────────
# Every network op is bounded, and GIT_TERMINAL_PROMPT=0 is the one that matters most: without it
# a box with no credential helper BLOCKS on an invisible username prompt until the calling tool is
# killed, which reads as "the rail hung" rather than "this box cannot authenticate".
TIMEOUT_BIN=""
for c in timeout gtimeout; do command -v "$c" >/dev/null 2>&1 && { TIMEOUT_BIN="$c"; break; }; done
git_b() { # <git args…>
  local rc pid w
  if [ -n "$TIMEOUT_BIN" ]; then
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true GIT_PAGER=cat GIT_OPTIONAL_LOCKS=0 \
      "$TIMEOUT_BIN" "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 "$@"
    return
  fi
  # No `timeout` on this box (stock macOS). A WATCHDOG, not a fallback to unbounded: the caller is
  # the landing rail, and an unbounded network read there is a hang, not a slow success.
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true GIT_PAGER=cat GIT_OPTIONAL_LOCKS=0 \
    git -C "$STORE" -c gc.auto=0 "$@" &
  pid=$!
  ( sleep "$MAX_WAIT"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$pid"; rc=$?
  kill -TERM "$w" 2>/dev/null
  wait "$w" 2>/dev/null
  return "$rc"
}

# ── fields ───────────────────────────────────────────────────────────────────────────────
# sed, not jq: record-review.sh WRITES a record with one printf in a fixed field order and reads
# its own fields back the same way, so a second JSON parser here would be a second definition of
# the record's shape (the same reason that script's record_identity() is an exact-string compare).
field() { # <file> <name>
  sed -n "s/.*\"$2\":\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" 2>/dev/null | command head -1
}

# ── what the CONSUMER can actually use ───────────────────────────────────────────────────
# `read_record` (scripts/atomic-land.sh) parses the file as STRICT JSON and then requires a 40-hex
# `head_sha` ("carries no usable head_sha") and a verdict; `review-enforcer` reads the same shape.
# A peer record that fails that is not a NEWER verdict — it is an UNREADABLE one, and letting it win
# the ordering comparison REPLACED a usable local record with bytes the rail refuses (reproduced: a
# peer record with trailing garbage, at a newer stamp, was pulled over a valid `clean` record, and
# the rail then refused with "carries no usable head_sha"; a record with no head_sha did the same
# and the run reported `wrote=1 … unreadable=0`, exit 0). So usability is checked BEFORE a peer
# record may win or be installed, and an unusable one is counted `unreadable` (exit 4).
record_usable() { # <file> → 0 when this box's reader can use it
  local f="$1"
  # ⛔ THE CHECK IS THE READER'S OWN, at the TOP LEVEL of the JSON — not `field` (a greedy sed that
  # takes the LAST match on the line). A record whose top-level `head_sha` is empty but which
  # carries a nested 40-hex one inside, say, an `evidence` object PASSED the old sed-based gate and
  # was installed over a usable local record; `read_record` then read `head_sha=''` and refused
  # ("carries no usable head_sha") — the exact regression this gate exists to prevent, reached
  # through the value parse instead of the syntax parse.
  command -v python3 >/dev/null 2>&1 || {
    warn "  ⚠️ python3 is not available, so a record cannot be checked against this box's reader — refusing to install one."
    return 1
  }
  python3 - "$f" <<'PY' >/dev/null 2>&1 || return 1
import json, re, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if not isinstance(d, dict):
    sys.exit(1)
h, v = d.get("head_sha", ""), d.get("verdict", "")
if not (isinstance(h, str) and re.fullmatch(r"[0-9a-fA-F]{40}", h)):
    sys.exit(1)
if not (isinstance(v, str) and v.strip()):
    sys.exit(1)
PY
  return 0
}

# ── equal `reviewed_at`, different bytes: WHICH KIND of difference is it? ─────────────────
# Rule 4 reports a DISAGREEMENT. Two records that agree on the verdict and on the HEAD are not
# disagreeing — they differ only in carry PROVENANCE, and calling that a conflict made a carried
# verdict unpublishable for ever: two boxes each carrying their own local record onto the same head
# produce the same head and verdict with different `carried_from`, and every union then exited 3
# with a "reconcile by hand" the operator cannot act on. (A carry of a carry, whose `carried_from`
# names an intermediate head rather than the peer's, is still reported as a conflict — that is
# genuinely ambiguous ordering, and rule 4 says report rather than guess.)
same_stamp_relation() { # <a> <b> → a | b | same | conflict
  local a="$1" b="$2" av bv ah bh am bm amb bmb
  av="$(field "$a" verdict)"; bv="$(field "$b" verdict)"
  # A different VERDICT is the one real disagreement at a shared mint time — unchanged.
  if [ -z "$av" ] || [ "$av" != "$bv" ]; then printf 'conflict'; return 0; fi
  ah="$(field "$a" head_sha)"; bh="$(field "$b" head_sha)"
  am="$(field "$a" mint)";     bm="$(field "$b" mint)"
  # The merge base is GATE-READ (the rail's B10/B12 comparison; clean-low's binding), so two records
  # that agree on verdict and head but disagree on it are a real disagreement, not provenance.
  amb="$(field "$a" merge_base_sha)"; bmb="$(field "$b" merge_base_sha)"
  if [ -n "$amb" ] && [ -n "$bmb" ] && [ "$amb" != "$bmb" ]; then printf 'conflict'; return 0; fi
  if [ "$ah" = "$bh" ]; then
    # Same head, same verdict: provenance-only. Prefer the carried side if exactly one is carried;
    # two carries of one head are the same record for every reader, so neither is written.
    if [ "$am" = "carried" ] && [ "$bm" != "carried" ]; then printf 'a'; return 0; fi
    if [ "$bm" = "carried" ] && [ "$am" != "carried" ]; then printf 'b'; return 0; fi
    printf 'same'; return 0
  fi
  # Different heads: the only thing that can certify which one supersedes is the record's own
  # lineage (`supersedes`), which the callers test first. Anything else is a conflict.
  printf 'conflict'
}

# ── the store ────────────────────────────────────────────────────────────────────────────
# The store is the ONE repo whose `refs/reviews/*` namespace the fleet shares: an agent-infra
# checkout, resolved from an explicit --repo, then $AGENT_INFRA_PATH, then this script's own
# parent (a repo copy). The FARMED copy at ~/.pi/agent/scripts/ has no repo above it, so it falls
# back to $AGENT_INFRA_PATH and REFUSES loudly rather than "syncing" nothing.
is_repo() { [ -n "${1:-}" ] && [ -d "$1" ] && git -C "$1" rev-parse --git-dir >/dev/null 2>&1; }
STORE=""
resolve_store() {
  local cand tried=""
  for cand in "$STORE_ARG" "${AGENT_INFRA_PATH:-}" "$SELF_DIR/.."; do
    [ -n "$cand" ] || continue
    tried="$tried '$cand'"
    is_repo "$cand" || continue
    # A repo WITHOUT the remote is not the store, and it must not end the search: an explicit
    # --repo naming a checkout whose remote is spelled differently would otherwise disable sync
    # even though $AGENT_INFRA_PATH can reach the namespace.
    STORE="$(cd "$cand" && pwd)"
    if git_b remote get-url "$REMOTE" >/dev/null 2>&1; then return 0; fi
    warn "registry-sync.sh: '$STORE' is a checkout but has no remote '$REMOTE' — trying the next candidate."
    STORE=""
  done
  warn "registry-sync.sh: no usable review-record store (a checkout WITH a '$REMOTE' remote). Tried:$tried"
  warn "  The refs live on ONE repo's remote; without such a checkout this box cannot reach them — pass --repo <agent-infra checkout>."
  return 1
}

# ── the STORE's own view — never this box's cache ────────────────────────────────────────
# ⛔ THE STORE'S LISTING IS THE ONLY TRUTH ABOUT WHAT THE STORE HOLDS. The key list used to be
# read from this checkout's LOCAL `refs/reviews/*` — a cache the fetch maintains — and because the
# fetch is deliberately not `--prune` (rule 2), a ref deleted on the store survived locally for
# ever. Measured consequence: after an out-of-band deletion, `push` compared a record against a
# cached copy of ITSELF, answered `same`, pushed nothing and exited 0 while the store held ZERO
# refs; `status` printed an `origin records=1` the store did not have. That is the false
# "converged" this file exists to remove — and it also made the `--force-with-lease` value a stale
# local OID, so a legitimate re-publish could never succeed ("stale info", every run).
#
# So the keys AND the OIDs come from `ls-remote` — the command the old fetch-failure arm already
# trusted — and the local refs are CACHE ONLY: the fetch exists to bring the OBJECTS those OIDs
# name into this checkout. An object we cannot read is reported per record as UNREADABLE (exit 4),
# never answered from a stale local ref.
STORE_REFS=""
fetch_refs() {
  local listing=""
  if ! listing="$(git_b ls-remote --quiet --refs "$REMOTE" 'refs/reviews/*' 2>/dev/null)"; then
    warn "registry-sync.sh: cannot READ the '$REMOTE' registry from '$STORE' — it is UNKNOWN, not empty. Not syncing."
    return 1
  fi
  STORE_REFS="$listing"
  [ -z "$listing" ] && return 0
  # NOT `--prune` (rule 2), and no longer load-bearing for the key list: it only carries objects.
  if ! git_b fetch --no-tags --quiet "$REMOTE" '+refs/reviews/*:refs/reviews/*' >/dev/null 2>&1; then
    warn "registry-sync.sh: ⚠️ the FETCH from '$REMOTE' failed while the store still lists refs — this run"
    warn "  continues from the store's own listing, and every record whose objects are not already here"
    warn "  is reported UNREADABLE (exit 4) rather than answered from a stale local ref."
  fi
  return 0
}

remote_refs() {
  printf '%s\n' "$STORE_REFS" | awk 'NF >= 2 { sub(/^refs\/reviews\//, "", $2); print $2 }' | LC_ALL=C sort
}
store_oid() { # <key> → the commit the STORE names for that ref (empty: the store has no such ref)
  printf '%s\n' "$STORE_REFS" | awk -v want="refs/reviews/$1" '$2 == want { print $1; exit }'
}
remote_record() { # <key> → the record bytes carried by the STORE's own object
  local oid
  oid="$(store_oid "$1")"
  [ -n "$oid" ] || return 1
  git_b show "$oid:record.json" 2>/dev/null
}

# ── the registry ─────────────────────────────────────────────────────────────────────────
registry_names() { # one filename per line (absent dir → nothing)
  local f
  [ -d "$REG_DIR" ] || return 0
  for f in "$REG_DIR"/*.json; do
    [ -e "$f" ] || continue            # unmatched glob
    printf '%s\n' "${f##*/}"
  done | LC_ALL=C sort
}

write_local() { # <key> <content-file>
  mkdir -p "$REG_DIR" || { warn "registry-sync.sh: cannot create $REG_DIR"; return 1; }
  # A registry entry is data, never a pointer into another tree: refuse to write through a symlink
  # (the same posture admin-merge.sh takes when it refuses a non-regular record path).
  if [ -L "$REG_DIR/$1.json" ]; then
    warn "registry-sync.sh: $REG_DIR/$1.json is a SYMLINK — refusing to write through it."
    return 1
  fi
  local tmp="$REG_DIR/.$1.sync.$$"
  cp "$2" "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$REG_DIR/$1.json"
}

same_bytes() { [ -f "$1" ] && [ -f "$2" ] && cmp -s "$1" "$2"; }

PUSHED=0 SKIPPED_OLDER=0 SAME=0 WROTE=0 CONFLICT=0 UNKEYED=0 UNREADABLE=0 FAILED=0 PUSH_FAILED=0
CONFLICT_KEYS=""

conflict() { # <key> <local-at> <remote-at> <local-file>
  CONFLICT=$((CONFLICT + 1))
  CONFLICT_KEYS="$CONFLICT_KEYS $1"
  warn "  ⚠️ CONFLICT $1 — reviewed_at '$2' on this box and '$3' on the peer are the SAME but the records differ (local head $(field "$4" head_sha 2>/dev/null | cut -c1-12)…). Neither side was overwritten (#2374 rule 4); reconcile by hand if these are not two recordings of one revision."
}

# ── the push DECISION, re-run on EVERY attempt ──────────────────────────────────────────
# ⛔ THE DECISION IS NOT TAKEN ONCE. It used to be: the first attempt compared, the push was
# refused (a peer had moved the ref), and the retry re-read the ref only to acquire a new lease
# value — so it force-pushed over the record the peer had just published. Reproduced with a
# mid-push peer write: origin's NEWER record was replaced by this box's older one, `pushed=1`,
# rc 0. The retry therefore calls this function again, and an attempt can only push the exact
# state it just compared.
DEC=""; DEC_MSG=""; DEC_PEER_AT=""; DEC_EXP=""
push_decision() { # <key> <file>  → DEC = push | skip | same | supersede | unreadable | conflict
  local key="$1" f="$2" tmp lat rat
  DEC="push"; DEC_MSG=""
  lat="$(field "$f" reviewed_at)"
  # "No ref" and "a ref whose record this box cannot read" are DIFFERENT states, and the second
  # is a peer record that must not be replaced: a bare `remote_record` yields empty for both.
  # ⛔ THE LEASE VALUE COMES FROM THE STORE'S OWN LISTING, never from the local ref cache: a ref
  # deleted on the store with nothing pruning it locally left the cache naming a commit the store no
  # longer had, so every re-publish was refused `stale info` on every run (a record that could
  # never be restored). An absent store ref is a CREATE, and `--force-with-lease` is not used.
  DEC_EXP="$(store_oid "$key")"
  if [ -z "$DEC_EXP" ]; then return 0; fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/registry-sync-remote.XXXXXX")" || { DEC="unreadable"; DEC_MSG="could not stage the peer's record"; return 0; }
  if ! remote_record "$key" >"$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    rm -f "$tmp"
    DEC="unreadable"; DEC_MSG="the peer's ref carries no readable record.json"
    return 0
  fi
  rat="$(field "$tmp" reviewed_at)"
  DEC_PEER_AT="$rat"
  if [ -z "$rat" ]; then
    rm -f "$tmp"
    DEC="unreadable"; DEC_MSG="the peer's record carries no readable reviewed_at, so which side is newer is UNKNOWN"
    return 0
  fi
  if [[ "$rat" > "$lat" ]]; then
    rm -f "$tmp"; DEC="skip"; DEC_MSG="the peer is NEWER ($rat > $lat)"; return 0
  fi
  if [ "$rat" = "$lat" ]; then
    if same_bytes "$f" "$tmp"; then rm -f "$tmp"; DEC="same"; return 0; fi
    # A CARRY keeps the mint time and changes the head (record-review.sh's carry arm), so a
    # carried record is born at the SAME reviewed_at as the record it supersedes. Treating that
    # as a rule-4 conflict would mean a carried verdict could never be published — the arm
    # atomic-land.sh is built around would leave the store pinned to the pre-carry head forever.
    # The supersession is checkable from the record's OWN lineage (carried_from names the head
    # the verdict was carried from), so it is decided by evidence, and it is REPORTED.
    if supersedes "$f" "$tmp"; then
      DEC="supersede"; DEC_MSG="this box's record CARRIES the peer's (carried_from=$(field "$f" carried_from | cut -c1-12)…), same mint time"
      rm -f "$tmp"; return 0
    fi
    if supersedes "$tmp" "$f"; then
      rm -f "$tmp"; DEC="skip"; DEC_MSG="the peer's record CARRIES this one (carried_from=$(field "$tmp" carried_from | cut -c1-12)…), same mint time"
      return 0
    fi
    # Neither side names the other's head. Agreeing on verdict AND head is provenance-only (the
    # parallel-carry case) and must not be reported as a divergence for ever.
    case "$(same_stamp_relation "$f" "$tmp")" in
      a) rm -f "$tmp"; DEC="supersede"; DEC_MSG="same mint time, same head, and THIS box's record is the carried one; publishing it as a supersession" ;;
      b) rm -f "$tmp"; DEC="skip"; DEC_MSG="same mint time and the peer's record is the carried one (same head, same verdict)" ;;
      same) rm -f "$tmp"; DEC="same"; DEC_MSG="same mint time, verdict, head and merge base — the records differ only in carry provenance" ;;
      *) rm -f "$tmp"; DEC="conflict" ;;
    esac
    return 0
  fi
  rm -f "$tmp"
  return 0
}

# supersedes <carried> <other> — true when <carried> is a CARRY of <other>: the same mint time and
# a `carried_from` that names <other>'s head. Anything else is a disagreement, not a supersession.
supersedes() {
  [ "$(field "$1" mint)" = "carried" ] || return 1
  # ⛔ A CARRY MAY NOT SUPERSEDE A DISAGREEING VERDICT. `supersedes` runs BEFORE
  # `same_stamp_relation` (whose first act is the verdict comparison), so without this test a
  # carried `clean` was published straight over a peer's `not-clean` at the SAME mint time —
  # silently replacing a refusal with a mergeable verdict on the fleet-visible record AND on the
  # pulling box (both reproduced). A legitimate carry re-binds the SAME verdict, so nothing real
  # is lost by requiring it.
  [ "$(field "$1" verdict)" = "$(field "$2" verdict)" ] || return 1
  local from
  from="$(field "$1" carried_from)"
  [ -n "$from" ] || return 1
  [ "$from" = "$(field "$2" head_sha)" ] || return 1
  [ -n "$from" ]
}

push_one() { # <key> <source-file>
  local key="$1" f="$2" lat cs exp rc blob tree commit attempt
  lat="$(field "$f" reviewed_at)"
  if [ -z "$lat" ]; then
    warn "  ⚠️ skip $key — the local record carries no readable reviewed_at, so no ordering rule can be applied to it."
    UNREADABLE=$((UNREADABLE + 1)); return 0
  fi
  cs="$(field "$f" reviewed_at)"
  attempt=0
  while :; do
    attempt=$((attempt + 1))
    push_decision "$key" "$f"
    case "$DEC" in
      skip) log_line "  · keep $key — $DEC_MSG; a record is never overwritten with an older one (#2374 rule 1)"
              SKIPPED_OLDER=$((SKIPPED_OLDER + 1)); return 0 ;;
      same)   [ -n "$DEC_MSG" ] && log_line "  · $key — $DEC_MSG"; SAME=$((SAME + 1)); return 0 ;;
      supersede) log_line "  · $key — $DEC_MSG; publishing it (a carry is a supersession, not a disagreement)" ;;
      unreadable) warn "  ⚠️ skip $key — $DEC_MSG; refusing to overwrite it (#2374 rule 1)."
              UNREADABLE=$((UNREADABLE + 1)); return 0 ;;
      conflict) conflict "$key" "$lat" "$DEC_PEER_AT" "$f"; return 0 ;;
    esac
    # ⛔ NO FETCH HERE. `exp` is the ref value `push_decision` actually compared: re-reading it
    # after a fetch would make the lease name the peer's CURRENT value (a no-op fence) and the push
    # an unconditional force — which is how a newer peer record was silently replaced by an older
    # one. A refusal means the state moved, and the loop below re-decides against the new state.
    exp="$DEC_EXP"
    blob="$(git_b hash-object -w "$f" 2>/dev/null)" || break
    tree="$(printf '100644 blob %s\trecord.json\n' "$blob" | git_b mktree 2>/dev/null)" || break
    commit="$(git_b -c user.name=registry-sync -c user.email=registry-sync@localhost \
      commit-tree "$tree" -m "review record $key reviewed_at=$cs" 2>/dev/null)" || break
    if [ -n "$exp" ]; then
      git_b push --quiet --force-with-lease="refs/reviews/$key:$exp" "$REMOTE" "$commit:refs/reviews/$key" >/dev/null 2>&1
    else
      git_b push --quiet "$REMOTE" "$commit:refs/reviews/$key" >/dev/null 2>&1
    fi
    rc=$?
    if [ "$rc" -eq 0 ]; then
      git_b update-ref "refs/reviews/$key" "$commit" >/dev/null 2>&1
      log_line "  ↑ pushed $key (reviewed_at=$cs)"
      PUSHED=$((PUSHED + 1)); WROTE=$((WROTE + 1)); return 0
    fi
    # A refusal means the state CHANGED under this attempt. Loop again so the DECISION is re-taken
    # against what is actually there now — never re-push the comparison this attempt just lost.
    if [ "$attempt" -ge 2 ]; then break; fi
    fetch_refs >/dev/null 2>&1
  done
  warn "  ⚠️ FAILED $key — the push was refused twice (a peer moved the ref, or this box cannot push to $REMOTE). The record stays LOCAL and is not lost; re-run to retry."
  FAILED=$((FAILED + 1)); PUSH_FAILED=$((PUSH_FAILED + 1)); return 0
}

pull_one() { # <key>
  local key="$1" tmp lf rat lat pull_reason=""
  tmp="$(mktemp "${TMPDIR:-/tmp}/registry-sync-pull.XXXXXX")" || { FAILED=$((FAILED + 1)); return 0; }
  if ! remote_record "$key" >"$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    # The ref exists (it came from remote_refs) but carries no readable record.json: that is a
    # DEFECT in the store, not "nothing to pull". Reported, because `status` would otherwise list
    # it as `missing here` forever while every other verb said "converged".
    # ⛔ THE TEST IS THE STORE'S OWN LISTING, never this box's cache. It used to be
    # `git rev-parse refs/reviews/$key`, which succeeds only when the box ALREADY cached the ref —
    # so a store ref whose OBJECTS were never fetched (a failed fetch, or a box that had never seen
    # it) was skipped with no counter and no warning, and `union` exited 0 over a registry it did
    # not receive: the false "converged" this file exists to delete, in the one state a BLIND box
    # is in. The key came from the store's listing, so the store demonstrably has the ref.
    if [ -n "$(store_oid "$key")" ]; then
      warn "  ⚠️ skip $key — the store lists this ref but its record.json is not readable here (the fetch did not bring its objects)."
      UNREADABLE=$((UNREADABLE + 1))
    fi
    rm -f "$tmp"; return 0
  fi
  rat="$(field "$tmp" reviewed_at)"
  if [ -z "$rat" ]; then
    warn "  ⚠️ skip $key — the peer's record carries no readable reviewed_at."
    rm -f "$tmp"; UNREADABLE=$((UNREADABLE + 1)); return 0
  fi
  # ⛔ USABILITY BEFORE ORDERING. A record the rail cannot read must never win the comparison: it
  # would replace a usable local record with bytes `read_record` refuses (see `record_usable`).
  if ! record_usable "$tmp"; then
    warn "  ⚠️ skip $key — the peer's record is not one this box's rail can USE (no 40-hex head_sha, no verdict, or not strict JSON); refusing to install it over $(if local_record_for_key "$key" >/dev/null 2>&1; then echo 'the local record'; else echo 'nothing'; fi)."
    rm -f "$tmp"; UNREADABLE=$((UNREADABLE + 1)); return 0
  fi
  # ⛔ THE KEY MUST MATCH WHAT THE RECORD SAYS IT IS, on the way IN as well as out. `push` refuses
  # to publish a record whose own repo/pr disagree with its key; without the same test here, a
  # mis-keyed ref is MATERIALISED under that key, and `read_record` (which validates only
  # head_sha/verdict) then hands another repo's verdict to this PR's gate — the #426 collapse that
  # rule 3 exists to prevent, open on one side.
  # ⚠️ COUNTED `unreadable`, NOT `unkeyed`: `unkeyed` is the INFORMATIONAL class for this box's own
  # repo-less legacy files (rule 3, which must stay quiet or every box with one reports a defect
  # for ever). A peer ref the store cannot attribute is a DEFECT IN THE STORE, and the header's
  # exit-4 contract says so — counting it `unkeyed` reported `converged` (rc 0) over a store whose
  # only record this box could not use, and the rail's rc-0 arm then discarded the warning.
  local rec_repo rec_pr
  rec_repo="$(field "$tmp" repo)"
  rec_pr="$(field "$tmp" pr)"
  if ! [[ "$rec_pr" =~ ^[0-9]+$ ]]; then
    warn "  ⚠️ skip $key — the peer's record carries no usable pr field, so the key it sits under cannot be verified."
    UNREADABLE=$((UNREADABLE + 1)); rm -f "$tmp"; return 0
  fi
  if [ -z "$rec_repo" ]; then
    warn "  ⚠️ skip $key — the peer's record carries no repo field, so the key it sits under cannot be verified (#2374 rule 3)."
    UNREADABLE=$((UNREADABLE + 1)); rm -f "$tmp"; return 0
  fi
  if [ "${rec_repo%/*}-${rec_repo#*/}-$rec_pr" != "$key" ]; then
    warn "  ⚠️ skip $key — the peer's record says ${rec_repo}#${rec_pr}, which is NOT this key; materialising it would transplant another repo's verdict (#2374 rule 3, #426)."
    UNREADABLE=$((UNREADABLE + 1)); rm -f "$tmp"; return 0
  fi
  lf=""
  if lf="$(local_record_for_key "$key")" && [ -n "$lf" ]; then
    same_bytes "$lf" "$tmp" && { SAME=$((SAME + 1)); rm -f "$tmp"; return 0; }
    lat="$(field "$lf" reviewed_at)"
    if [ -n "$lat" ] && [[ "$lat" > "$rat" ]]; then
      log_line "  · keep $key — this box is NEWER ($lat > $rat); an older record never overwrites a newer one (#2374 rule 1)"
      SKIPPED_OLDER=$((SKIPPED_OLDER + 1)); rm -f "$tmp"; return 0
    fi
    if [ -z "$lat" ]; then
      warn "  ⚠️ skip $key — this box's record carries no readable reviewed_at; refusing to overwrite an unknown-order record (#2374 rule 1)."
      UNREADABLE=$((UNREADABLE + 1)); rm -f "$tmp"; return 0
    fi
    if [ "$lat" = "$rat" ]; then
      # The peer's record supersedes this box's only when it is a CARRY of it (same mint time, and
      # `carried_from` names the head this box holds) — the carry arm keeps the stamp, so treating
      # that as a conflict would strand every carried verdict on the box that did not mint it.
      if supersedes "$tmp" "$lf"; then
        pull_reason="the peer's record CARRIES this box's (carried_from=$(field "$tmp" carried_from | cut -c1-12)…), same mint time; a carry is a supersession"
      elif supersedes "$lf" "$tmp"; then
        log_line "  · keep $key — this box's record CARRIES the peer's (carried_from=$(field "$lf" carried_from | cut -c1-12)…), same mint time"
        SKIPPED_OLDER=$((SKIPPED_OLDER + 1)); rm -f "$tmp"; return 0
      else
        # Neither names the other's head: same verdict+head is provenance-only (the parallel carry
        # two boxes make onto one head); a different verdict is the real disagreement.
        case "$(same_stamp_relation "$tmp" "$lf")" in
          a) pull_reason="same mint time, same head, and the peer's record is the carried one; taking it as a supersession" ;;
          b) log_line "  · keep $key — same mint time and THIS box's record is the carried one (same head, same verdict)"
             SKIPPED_OLDER=$((SKIPPED_OLDER + 1)); rm -f "$tmp"; return 0 ;;
          same) log_line "  · keep $key — same mint time, verdict, head and merge base; the records differ only in carry provenance"
             SAME=$((SAME + 1)); rm -f "$tmp"; return 0 ;;
          *) conflict "$key" "$lat" "$rat" "$lf"; rm -f "$tmp"; return 0 ;;
        esac
      fi
    fi
  fi
  if write_local "$key" "$tmp"; then
    log_line "  ↓ pulled $key (reviewed_at=$rat)${pull_reason:+ — $pull_reason}"
    WROTE=$((WROTE + 1))
  else
    warn "  ⚠️ FAILED $key — could not write $REG_DIR/$key.json"
    FAILED=$((FAILED + 1))
  fi
  rm -f "$tmp"; return 0
}

# ── which local files may be replicated (rule 3) ─────────────────────────────────────────
# A qualified filename is authoritative ONLY when the record embeds a repo that the name claims.
# A LEGACY `<pr>.json` is keyed by its EMBEDDED repo (never by its name), and not at all when it
# has none — two repos' legacy files are indistinguishable by name, which is the #426 collision.
#
# It writes `<key>\t<filename>` lines to the path in $1 and its SKIP diagnostics to STDERR, and it
# must be called in THIS shell (never inside `$(…)` or a pipeline): it increments the run's
# counters, and a subshell's increment is lost — a rule-3 refusal would then be reported as
# `unkeyed=0`, and its `say` lines, written to the data stream, would be re-read as record names.
local_keyed() { # <outfile>
  local out="$1" name base repo pr rec_pr
  : > "$out" || return 1
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    base="${name%.json}"
    if [[ "$base" =~ ^[A-Za-z0-9_.-]+-[A-Za-z0-9_.-]+-[0-9]+$ ]]; then
      repo="$(field "$REG_DIR/$name" repo)"
      if [ -z "$repo" ]; then
        warn "  · skip $base — qualified name but no repo field, so the key it claims cannot be verified"
        UNKEYED=$((UNKEYED + 1)); continue
      fi
      if [ "$base" != "${repo%/*}-${repo#*/}-$(field "$REG_DIR/$name" pr)" ]; then
        warn "  · skip $base — the name disagrees with the record's own repo/pr fields (repo=$repo, pr=$(field "$REG_DIR/$name" pr))"
        UNKEYED=$((UNKEYED + 1)); continue
      fi
      printf '%s\t%s\n' "$base" "$name" >> "$out"; continue
    fi
    if [[ "$base" =~ ^[0-9]+$ ]]; then
      repo="$(field "$REG_DIR/$name" repo)"; pr="$base"
      rec_pr="$(field "$REG_DIR/$name" pr)"
      if [ -z "$repo" ] || [[ "$repo" != */* ]]; then
        warn "  · skip $base.json — a legacy number-keyed record with no readable 'owner/name' repo field cannot be attributed to a repo, so it is never replicated under a name that would claim one (#2374 rule 3)"
        UNKEYED=$((UNKEYED + 1)); continue
      fi
      # ⛔ THE LEGACY NAME IS NOT THE RECORD'S IDENTITY. The qualified branch compares the name to
      # the record's own repo AND pr; this arm used to take `pr` from the FILENAME only, so
      # `441.json` whose record says `"pr":442` was published as `…-441` — a ref whose name its own
      # payload denies, which every peer then refuses (and, having no delete path, nothing can
      # clear). Reproduced before this check.
      if [ "${rec_pr:-}" != "$pr" ]; then
        warn "  · skip $base.json — the filename says #$pr but the record's own pr field says #${rec_pr:-<none>}; publishing it would put a record under a key its own fields deny (#2374 rule 3)"
        UNKEYED=$((UNKEYED + 1)); continue
      fi
      printf '%s-%s-%s\t%s\n' "${repo%/*}" "${repo#*/}" "$pr" "$name" >> "$out"; continue
    fi
    warn "  · skip $name — not a registry record name"
    UNKEYED=$((UNKEYED + 1))
  done
}

# The file the READER would act on for this key. `read_record` (atomic-land.sh) prefers the
# qualified name and falls back to a legacy `<pr>.json` that names no repo or names THIS one — so
# a comparison that looked only at the qualified path would miss a NEWER legacy record sitting
# beside it, and materialising an older qualified record would SHADOW the newer verdict.
local_record_for_key() { # <key>
  local key="$1" q="$REG_DIR/$1.json" lf pr legacy_repo
  if [ -f "$q" ] && [ ! -L "$q" ]; then printf '%s' "$q"; return 0; fi
  pr="${key##*-}"
  lf="$REG_DIR/$pr.json"
  if [ -f "$lf" ] && [ ! -L "$lf" ]; then
    # ⛔ THE OWNER/REPO SPLIT IS NOT DERIVABLE FROM THE KEY: owner AND repo may each contain a
    # dash (`daniel-ospina-agent-infra`), so any `-`→`/` substitution picks the wrong boundary and
    # the legacy record is silently missed. Derive the key FROM THE RECORD'S OWN repo instead and
    # require it to equal the key — the same identity test `local_keyed` applies to a qualified name.
    legacy_repo="$(field "$lf" repo)"
    if [ -z "$legacy_repo" ] || [ "${legacy_repo%/*}-${legacy_repo#*/}-$pr" = "$key" ]; then
      printf '%s' "$lf"; return 0
    fi
  fi
  return 1
}

do_pull() {
  fetch_refs || return 1
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    pull_one "$key"
  done <<<"$(remote_refs)"
}

do_push() {
  fetch_refs || return 1
  local key name list
  list="$(mktemp "${TMPDIR:-/tmp}/registry-sync-keys.XXXXXX")" || return 1
  local_keyed "$list" <<<"$(registry_names)"
  while IFS=$'\t' read -r key name; do
    [ -n "$key" ] || continue
    push_one "$key" "$REG_DIR/${name:-$key.json}"
  done < "$list"
  rm -f "$list"
}

registry_hash() {
  [ -d "$REG_DIR" ] || { printf 'none'; return 0; }
  local f
  ( cd "$REG_DIR" 2>/dev/null || exit 0
    for f in *.json; do
      [ -e "$f" ] || continue
      printf '%s ' "$f"; command cat "$f" 2>/dev/null; printf '\n'
    done ) | if command -v sha256sum >/dev/null 2>&1; then sha256sum; else shasum -a 256; fi \
      | awk '{print $1}'
}

# `status` is a REPORT. It always exits 0 — a caller must be able to distinguish "records are
# missing here" (a fact it can act on, printed as missing_here=N) from "this box cannot read the
# store" (an error, exit 1 from fetch_refs). Conflating the two made exit 1 mean both.
do_status() {
  fetch_refs || return 1
  local key name at list lnew="" rnew="" local_n=0 remote_n=0 missing=0
  list="$(mktemp "${TMPDIR:-/tmp}/registry-sync-status.XXXXXX")" || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    remote_n=$((remote_n + 1))
    at="$(remote_record "$key" 2>/dev/null | sed -n 's/.*"reviewed_at":"\([^"]*\)".*/\1/p' | command head -1)"
    if [ -n "$at" ] && { [ -z "$rnew" ] || [[ "$at" > "$rnew" ]]; }; then rnew="$at"; fi
    # "Missing here" means the READER would find nothing — the qualified file OR the legacy
    # `<pr>.json` it falls back to. Counting only the qualified name reported a record as absent
    # that the gate already uses, and `pull` then correctly refused to materialise it, so the
    # report contradicted every other verb.
    if ! local_record_for_key "$key" >/dev/null 2>&1; then
      missing=$((missing + 1))
      printf '  missing here: %s\n' "$key"
    fi
  done <<<"$(remote_refs)"
  local_keyed "$list" <<<"$(registry_names)"
  while IFS=$'\t' read -r key name; do
    [ -n "$key" ] || continue
    local_n=$((local_n + 1))
    at="$(field "$REG_DIR/$name" reviewed_at)"
    if [ -n "$at" ] && { [ -z "$lnew" ] || [[ "$at" > "$lnew" ]]; }; then lnew="$at"; fi
  done < "$list"
  rm -f "$list"
  printf 'local  records=%s newest_reviewed_at=%s hash=%s\n' "$local_n" "${lnew:-none}" "$(registry_hash)"
  printf 'origin records=%s newest_reviewed_at=%s\n' "$remote_n" "${rnew:-none}"
  printf 'missing_here=%s\n' "$missing"
  return 0
}

summary() { # <verb>
  printf '%s: wrote=%s pushed=%s same=%s older_refused=%s conflicts=%s unkeyed=%s unreadable=%s failed=%s\n' \
    "$1" "$WROTE" "$PUSHED" "$SAME" "$SKIPPED_OLDER" "$CONFLICT" "$UNKEYED" "$UNREADABLE" "$FAILED"
  if [ "$FAILED" -gt 0 ]; then
    # WHICH SIDE failed matters at the caller: a failed PULL means the fleet is UNKNOWN here, while a
    # failed PUSH means the records WERE read and this box could not publish. Naming both as "the
    # fleet's records are UNKNOWN" sent an operator to re-run a path that fails identically.
    if [ "$PUSH_FAILED" -gt 0 ] && [ "$FAILED" -eq "$PUSH_FAILED" ]; then
      warn "registry-sync.sh: $FAILED record(s) could not be PUBLISHED — the pull side succeeded, so this box"
      warn "  HOLDs the fleet's records but its own are still LOCAL. Re-run to retry (nothing was deleted)."
    else
      warn "registry-sync.sh: $FAILED record(s) could not be moved — re-run to retry (nothing was deleted, and no record was overwritten with an older one)."
    fi
    return 1
  fi
  if [ "$CONFLICT" -gt 0 ]; then
    warn "registry-sync.sh: $CONFLICT record(s) DIVERGE at the same reviewed_at:$CONFLICT_KEYS"
    return 3
  fi
  if [ "$UNREADABLE" -gt 0 ]; then
    warn "registry-sync.sh: $UNREADABLE record(s) were SKIPPED because they could not be read or ordered — this is"
    warn "  NOT a converged state (the store holds records this box cannot use). Nothing was overwritten."
    return 4
  fi
  return 0
}

resolve_store || exit 1
case "$VERB" in
  pull)   do_pull  || exit 1; summary pull;  exit $? ;;
  push)   do_push  || exit 1; summary push;  exit $? ;;
  union)  do_pull  || exit 1; do_push || exit 1; summary union; exit $? ;;
  status) do_status || exit 1; exit 0 ;;
esac
