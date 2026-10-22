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
#      and the verb exits 3.
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

say()  { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }
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

# One fetch of the whole namespace. NOT `--prune` (rule 2). A fetch that fails for ANY reason is
# fatal for a verb that would otherwise read an empty namespace and report "converged".
fetch_refs() {
  local listing=""
  if git_b fetch --no-tags --quiet "$REMOTE" '+refs/reviews/*:refs/reviews/*' >/dev/null 2>&1; then
    return 0
  fi
  # A namespace that does not exist yet makes some git versions exit non-zero on that fetch. That
  # is benign ONLY when the remote answers and answers EMPTY. If the remote HAS refs and the fetch
  # still failed, the local refs are a stale snapshot — answering from them would report
  # "converged" from data this run never refreshed, which is the false PASS this file removes.
  if listing="$(git_b ls-remote --quiet --refs "$REMOTE" 'refs/reviews/*' 2>/dev/null)"; then
    [ -z "$listing" ] && return 0
    warn "registry-sync.sh: the FETCH from '$REMOTE' failed while the remote still lists refs — the local"
    warn "  namespace is a STALE SNAPSHOT, so no verb can answer from it. Not syncing (UNKNOWN, not empty)."
    return 1
  fi
  warn "registry-sync.sh: cannot read the '$REMOTE' registry from '$STORE' — it is UNKNOWN, not empty. Not syncing."
  return 1
}

remote_refs() { git_b for-each-ref --format='%(refname:strip=2)' refs/reviews 2>/dev/null | LC_ALL=C sort; }
remote_record() { git_b show "refs/reviews/$1:record.json" 2>/dev/null; }

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

PUSHED=0 SKIPPED_OLDER=0 SAME=0 WROTE=0 CONFLICT=0 UNKEYED=0 UNREADABLE=0 FAILED=0
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
  DEC_EXP="$(git_b rev-parse --verify --quiet "refs/reviews/$key" 2>/dev/null || true)"
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
    rm -f "$tmp"; DEC="conflict"; return 0
  fi
  rm -f "$tmp"
  return 0
}

# supersedes <carried> <other> — true when <carried> is a CARRY of <other>: the same mint time and
# a `carried_from` that names <other>'s head. Anything else is a disagreement, not a supersession.
supersedes() {
  [ "$(field "$1" mint)" = "carried" ] || return 1
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
      skip)   say "  · keep $key — $DEC_MSG; a record is never overwritten with an older one (#2374 rule 1)"
              SKIPPED_OLDER=$((SKIPPED_OLDER + 1)); return 0 ;;
      same)   SAME=$((SAME + 1)); return 0 ;;
      supersede) say "  · $key — $DEC_MSG; publishing it (a carry is a supersession, not a disagreement)" ;;
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
      say "  ↑ pushed $key (reviewed_at=$cs)"
      PUSHED=$((PUSHED + 1)); WROTE=$((WROTE + 1)); return 0
    fi
    # A refusal means the state CHANGED under this attempt. Loop again so the DECISION is re-taken
    # against what is actually there now — never re-push the comparison this attempt just lost.
    if [ "$attempt" -ge 2 ]; then break; fi
    fetch_refs >/dev/null 2>&1
  done
  warn "  ⚠️ FAILED $key — the push was refused twice (a peer moved the ref, or this box cannot push to $REMOTE). The record stays LOCAL and is not lost; re-run to retry."
  FAILED=$((FAILED + 1)); return 0
}

pull_one() { # <key>
  local key="$1" tmp lf rat lat pull_reason=""
  tmp="$(mktemp "${TMPDIR:-/tmp}/registry-sync-pull.XXXXXX")" || { FAILED=$((FAILED + 1)); return 0; }
  if ! remote_record "$key" >"$tmp" 2>/dev/null || [ ! -s "$tmp" ]; then
    # The ref exists (it came from remote_refs) but carries no readable record.json: that is a
    # DEFECT in the store, not "nothing to pull". Reported, because `status` would otherwise list
    # it as `missing here` forever while every other verb said "converged".
    if [ -n "$(git_b rev-parse --verify --quiet "refs/reviews/$key" 2>/dev/null || true)" ]; then
      warn "  ⚠️ skip $key — the peer's ref carries no readable record.json."
      UNREADABLE=$((UNREADABLE + 1))
    fi
    rm -f "$tmp"; return 0
  fi
  rat="$(field "$tmp" reviewed_at)"
  if [ -z "$rat" ]; then
    warn "  ⚠️ skip $key — the peer's record carries no readable reviewed_at."
    rm -f "$tmp"; UNREADABLE=$((UNREADABLE + 1)); return 0
  fi
  # ⛔ THE KEY MUST MATCH WHAT THE RECORD SAYS IT IS, on the way IN as well as out. `push` refuses
  # to publish a record whose own repo/pr disagree with its key; without the same test here, a
  # mis-keyed ref is MATERIALISED under that key, and `read_record` (which validates only
  # head_sha/verdict) then hands another repo's verdict to this PR's gate — the #426 collapse that
  # rule 3 exists to prevent, open on one side.
  local rec_repo rec_pr
  rec_repo="$(field "$tmp" repo)"
  rec_pr="$(field "$tmp" pr)"
  if ! [[ "$rec_pr" =~ ^[0-9]+$ ]]; then
    warn "  ⚠️ skip $key — the peer's record carries no usable pr field, so the key it sits under cannot be verified."
    UNKEYED=$((UNKEYED + 1)); rm -f "$tmp"; return 0
  fi
  if [ -z "$rec_repo" ]; then
    warn "  ⚠️ skip $key — the peer's record carries no repo field, so the key it sits under cannot be verified (#2374 rule 3)."
    UNKEYED=$((UNKEYED + 1)); rm -f "$tmp"; return 0
  fi
  if [ "${rec_repo%/*}-${rec_repo#*/}-$rec_pr" != "$key" ]; then
    warn "  ⚠️ skip $key — the peer's record says ${rec_repo}#${rec_pr}, which is NOT this key; materialising it would transplant another repo's verdict (#2374 rule 3, #426)."
    UNKEYED=$((UNKEYED + 1)); rm -f "$tmp"; return 0
  fi
  lf=""
  if lf="$(local_record_for_key "$key")" && [ -n "$lf" ]; then
    same_bytes "$lf" "$tmp" && { SAME=$((SAME + 1)); rm -f "$tmp"; return 0; }
    lat="$(field "$lf" reviewed_at)"
    if [ -n "$lat" ] && [[ "$lat" > "$rat" ]]; then
      say "  · keep $key — this box is NEWER ($lat > $rat); an older record never overwrites a newer one (#2374 rule 1)"
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
        say "  · keep $key — this box's record CARRIES the peer's (carried_from=$(field "$lf" carried_from | cut -c1-12)…), same mint time"
        SKIPPED_OLDER=$((SKIPPED_OLDER + 1)); rm -f "$tmp"; return 0
      else
        conflict "$key" "$lat" "$rat" "$lf"; rm -f "$tmp"; return 0
      fi
    fi
  fi
  if write_local "$key" "$tmp"; then
    say "  ↓ pulled $key (reviewed_at=$rat)${pull_reason:+ — $pull_reason}"
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
  local out="$1" name base repo pr
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
      if [ -z "$repo" ]; then
        warn "  · skip $base.json — a legacy number-keyed record with no repo field cannot be attributed to a repo, so it is never replicated under a name that would claim one (#2374 rule 3)"
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
    warn "registry-sync.sh: $FAILED record(s) could not be moved — re-run to retry (nothing was deleted, and no record was overwritten with an older one)."
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
