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
# Every summary line ends with `unchanged=N`: the number of records the CONVERGED PRE-PASS skipped
# as byte-identical (counted once per half, exactly as `same=` is — so a converged `union` reports
# `same=2N unchanged=2N`), plus `same=`, which the per-record path also increments for a record it
# examined and found identical.
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
#   the one failure this file exists to prevent. (#3180 made that cost acceptable WITHOUT reversing
#   this decision: a converged run now compares the store's own listing against the local files'
#   content hashes, in one batch, so nothing is remembered between runs and a stale cache cannot
#   exist. See "THE CONVERGED PRE-PASS" below.)
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
# ⛔ NO `jq`. ⛔ AND ONE DEFINITION OF THE RECORD'S SHAPE, NOT TWO (agent-infra#2510, #2374).
# `read_record` (scripts/atomic-land.sh) and `extensions/review-enforcer` parse a record as STRICT
# JSON and take its TOP-LEVEL value — and this file ORDERS records by `reviewed_at` and VERIFIES
# keys by `repo`/`pr`. So a field read that disagreed with the gate would decide the merge rules on
# one value while the gate acted on another. The `sed` (and #3180's spawn-free replica, which
# preserved its semantics on purpose) takes the LAST match on the LINE, which is a NESTED value
# whenever the record carries an object. Measured on this box: a record whose top level said
# `reviewed_at=2099…`, `repo=other/repo`, `pr=999` while a nested `evidence` object said
# `reviewed_at=2000…`, `repo=daniel-ospina/agent-infra`, `pr=2374` read back EVERY field from the
# nested side — so rule 3's key check PASSED a record belonging to another repo, and rule 1 ranked
# the store's newer record as older. Both directions lose a newer record, unrecoverably (one record
# per PR, no delete path, no history).
#
# SO THE READ IS THE READER'S PARSE. What keeps it cheap (#3180's win: a converged 4,027-record run
# must not spawn per record) is a SHAPE GATE, not a second semantics. A record whose bytes are ONE
# line, one outer `{…}`, and NO nested container can only be read one way: on such a line a
# last-match scan IS the top-level value — including a repeated key, which resolves to the LAST one,
# exactly as `json.load` resolves it — so that shape takes the spawn-free path. Everything else (a
# nested object or array, a multi-line file, anything that is not a JSON object) goes to `python3`'s
# strict parse. Every record `record-review.sh` writes is the flat shape (its `printf` emits one
# flat line), so the fast path is the whole real registry and the spawn cost is paid only on bytes
# that are anomalous by construction.
# No python3 ⇒ EMPTY, which every caller already treats as unreadable, so the run fails CLOSED and
# nothing is overwritten — the same posture as `record_usable`.
#
# ⛔ THREE trims, never one bracket class: `${rest%%[,\"}]*}` ends the EXPANSION at the `}` inside the
# class and leaves literal garbage in the value (reproduced). The three trims are order-independent:
# each takes the prefix before the first occurrence of its own character.
field() { # <file> <name>
  local f="$1" n="$2" l1="" l2="" l2_rc=0 rest tailp after
  [ -f "$f" ] || return 0
  { IFS= read -r l1 || :; IFS= read -r l2; l2_rc=$?; } < "$f" 2>/dev/null
  case "$l1" in
    '{'*'}')
      # ⛔ EOF AT THE END OF LINE ONE — not merely "the second read failed". A second read fails BOTH at
      # EOF and on an unterminated final line that still CARRIED data, so `{"…"}\nJUNK` (no trailing
      # newline) took the fast path while `json.load` refuses the file: a corrupt local file then won
      # rule 1/rule 4 at rc 0 with `unreadable=0`, REPLACED a usable peer record, and left the store
      # holding bytes no box can read — the fleet's only copy for that PR (measured). BOTH conditions
      # are required: the read must have failed AND brought back nothing.
      if [ "$l2_rc" -ne 0 ] && [ -z "$l2" ]; then
        # ⛔ a `}` inside a `${var//…}` pattern TERMINATES the expansion (measured: it yields the
        # input followed by a literal `]/}`), so the natural `[^}]` class silently does nothing
        # here. `case` patterns have no such problem, and stripping the outer braces by hand is
        # enough: any container character left in the INTERIOR means "not the flat shape" — and so
        # does ANY BACKSLASH, because a JSON escape (`\"`, `\/`, `\u…`) cannot be decoded by a prefix
        # trim (measured: `"repo":"a\/b"` read back as `a\`, a wrong rule-3 key).
        rest="${l1%\}}"; rest="${rest#*\{}"
        case "$rest" in
          *'{'*|*'}'*|*'['*|*']'*|*\\*) ;;
          *)
            case "$l1" in *"\"$n\":"*) ;; *) return 0 ;; esac
            rest="${l1##*"\"$n\":"}"    # greedy-LAST occurrence — on a flat line, THE top level
            # ⛔ THE VALUE MUST START AT THE COLON with an actual JSON scalar. `json.dumps`'s DEFAULT
            # separators emit `": "`, and a prefix trim does NOT skip whitespace — so a spaced record
            # read back as a single SPACE: non-empty (every unreadable guard passed) and sorting BELOW
            # any timestamp (`' '` < `'2'`), so `pull` OVERWROTE a NEWER local record with an older
            # peer one, silently, at rc 0 (measured — this file's own "unrecoverable" class).
            # `null`/`true`/`false` diverge the same way, so anything but a string or a number is the
            # READER's to answer: a shape this scan is not sure about cannot fail OPEN.
            # ⛔ AND A STRING RUNS TO ITS CLOSING QUOTE, never to the first `,`: `"repo":"a,b/c"` read
            # as `a` (measured), i.e. a wrong rule-3 key, and two same-stamp records differing only
            # after a comma compared `same`, so rule 4's divergence was never reported.
            case "$rest" in
              \"*)
                rest="${rest#\"}"
                tailp="${rest%%\"*}"          # escape-free by the gate above
                after="${rest#*\"}"           # whatever follows the closing quote
                case "$after" in
                  ,*|\}*) printf '%s' "$tailp"; return 0 ;;
                esac ;;
              -[0-9]*|[0-9]*)
                rest="${rest%%[,]*}"; rest="${rest%%\}*}"
                printf '%s' "$rest"; return 0 ;;
            esac
            _field_json "$f" "$n"; return 0 ;;
        esac
      fi ;;
  esac
  _field_json "$f" "$n"
}

# The reader's own parse, for a record whose shape cannot be read line-wise (see `field`). One
# `python3` per CALL, and only for those shapes — never for a record `record-review.sh` writes.
_field_json() { # <file> <name>
  command -v python3 >/dev/null 2>&1 || return 0
  python3 - "$1" "$2" <<'PY' 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)
except Exception:
    sys.exit(0)
v = d.get(sys.argv[2], "") if isinstance(d, dict) else ""
if v is None or isinstance(v, (dict, list)):
    v = ""
elif isinstance(v, bool):
    v = "true" if v else "false"
elif not isinstance(v, str):
    v = str(v)
print(v)
PY
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

# ── serialising compare+write ────────────────────────────────────────────────────────────
# `pull` reads this box's record, decides, then writes. Without a lock a record MINTED between the
# comparison and the rename is silently replaced by the peer's older bytes — rule 1 lost to a race,
# and unrecoverably (the store keeps one record per PR and there is no delete path). Nothing else
# that writes this directory takes a lock of its own (a `record-review.sh` mint, an operator's
# `registry-sync.sh pull`, and `cloud-cell-bringup.sh`'s union all land here), so the most a lock can
# do is exclude a CONCURRENT SYNC RUN — which is the interleaving that actually loses bytes on one
# box. There is ONE lock path (not one per key), so it DOES serialise keys across runs: a pull on
# `a-b-1` and a push on `c-d-2` in two concurrent runs wait for each other. That is a deliberate
# trade — the critical section is a compare plus one local rename (microseconds), and the network
# fetch that could take minutes is OUTSIDE it, in `remote_record`/`fetch_once`. The lock costs a
# second run a few hundred ms at worst, never the network bound.
#
# mkdir, not flock: flock is absent on stock macOS (this file already avoids `timeout` for the same
# reason). Bounded (~5 s) so a landing can never hang on it.
#
# ⛔ THE RECLAIM PREDICATE HAS TO BE RIGHT IN BOTH DIRECTIONS (#2510 review P2, both measured). The
# first cut tested `[ -n "$pid" ] && ! kill -0 "$pid"`, which is wrong twice:
#   · a lock directory with NO pid file — the holder killed between `mkdir` and the pid write, or a
#     truncated/empty one — NEVER satisfied it, so it was never reclaimed and every later pull skipped
#     EVERY changed record, for ever, until a human removed the directory. One kill = a permanent
#     wedge in the landing path, which is worse than the rare race the lock exists to prevent.
#   · `kill -0` reports EPERM as FAILURE, so a LIVE holder this process may not signal (another
#     user's run) read as GONE and its lock was STOLEN — reopening the very compare+write race the
#     lock closes. Liveness is therefore `ps -p`, which is permission-insensitive.
# So a lock is reclaimed when it has no usable holder AND is past LOCK_PID_GRACE (a live acquirer is
# legitimately pid-less for the microseconds between `mkdir` and the write — too short to matter, too
# long to ignore), or when it is past LOCK_STALE_MAX while showing a live pid (the pid was RECYCLED
# onto an unrelated process, which liveness alone cannot distinguish). No `stat` ⇒ no age ⇒ FAIL
# CLOSED (wait out the bound and let the caller refuse to write) rather than steal a lock we cannot
# date.
#
# ⛔ THE CEILING MUST OUTLIVE THE RUN'S OWN BOUND. `--timeout` is an operator knob (any positive
# integer), and the lock is held across a local compare+write — but a holder can be FROZEN, not dead
# (laptop lid-sleep mid-land, a SIGSTOPped lane, a hung filesystem): `ps -p` still succeeds, so only
# the ceiling can break it. A fixed 300 s would therefore reclaim a legitimate `--timeout 600` run in
# its own critical section, so the floor is `max(300, 2 × MAX_WAIT)`.
#
# ⛔ RECLAIM ATOMICALLY, AND RELEASE ONLY WHAT YOU STILL OWN. Two window races the first cut had:
#   · DECIDE-THEN-`rm -rf` IS NOT A CLAIM. Between the decision and the removal another run can
#     reclaim the same stale dir, acquire it, and have its LIVE lock deleted by this one (measured:
#     the pid flipped mid-critical-section and two holders overlapped 2.1 s). `mv` is the claim —
#     exactly ONE reclaimer can win a rename — and the claimed directory carries the pid the decision
#     was based on, so re-reading it afterwards tells us whether we removed the lock we judged.
#   · `reg_unlock` removed `$LOCKDIR` unconditionally. The ceiling arm can reclaim a lock that still
#     names a LIVE pid, so that holder reaches `reg_unlock` long after losing it and deletes the NEW
#     holder's lock, letting a third run into the critical section (measured). Release therefore
#     checks that the pid inside is still ours.
#
# ⛔ EVERY non-acquiring pass SLEEPS and INCREMENTS. The first cut `continue`d on the reclaim path
# without either, so a lock it could not remove — a root-owned lock left in a shared registry by a
# `sudo` run — HOT-SPUN with no bound at all (measured: 410 reclaim warnings in 4 s, never exits),
# inside atomic-land.sh's pre-sync. The ~5 s bound must hold in EVERY arm, not just the waiting one.
LOCK_PID_GRACE="${REGISTRY_SYNC_LOCK_PID_GRACE:-2}"    # s a pid-less lock must survive before reclaim
LOCK_STALE_MAX="${REGISTRY_SYNC_LOCK_STALE_MAX:-}"    # empty ⇒ derive: max(300, 2 × MAX_WAIT)
# A non-numeric tunable would make `[ -ge ]` ERROR (rc 2, so the arm silently flips) — sanitise, because
# a silently-flipped reclaim arm is either a stolen live lock or a restored permanent wedge. A
# DEGENERATE value (0) disables the lock just as effectively, so both arms carry a real floor.
case "$LOCK_PID_GRACE" in ''|*[!0-9]*) LOCK_PID_GRACE=2 ;; esac
[ "$LOCK_PID_GRACE" -ge 1 ] || LOCK_PID_GRACE=1
if [ -z "$LOCK_STALE_MAX" ]; then LOCK_STALE_MAX=$((MAX_WAIT * 2)); [ "$LOCK_STALE_MAX" -ge 300 ] || LOCK_STALE_MAX=300; fi
case "$LOCK_STALE_MAX" in ''|*[!0-9]*) LOCK_STALE_MAX=300 ;; esac
[ "$LOCK_STALE_MAX" -ge 1 ] || LOCK_STALE_MAX=300

lock_age() { # <path> → SECONDS since its mtime, "" when no `stat`/`date` can answer
  # ⛔ the AGE, not the MTIME: comparing an absolute epoch against a 300 s threshold is true for every
  # lock ever created, which reclaims LIVE locks on sight (reproduced in this file's own §30a/§30b).
  local m now
  m="$(stat -c %Y "$1" 2>/dev/null || true)"
  case "$m" in ''|*[!0-9]*) m="$(stat -f %m "$1" 2>/dev/null || true)" ;; esac
  case "$m" in ''|*[!0-9]*) printf ''; return 0 ;; esac
  now="$(date +%s 2>/dev/null || true)"
  case "$now" in ''|*[!0-9]*) printf ''; return 0 ;; esac
  # a FUTURE mtime (clock skew) is 0s old, never a negative age
  if [ "$now" -ge "$m" ]; then printf '%s' "$((now - m))"; else printf '0'; fi
}

# claim_stale <pid-when-judged> <message> → 0 = the lock this run judged is gone
# `mv` is the atomic claim; exactly one reclaimer can win it. If the directory that landed under the
# scratch name does not carry the pid the decision was made on, it is NOT the lock we judged — either
# a peer reclaimed it and re-created it, or it is brand new — so it is PUT BACK and this run waits,
# never deleted. A claimed directory that cannot be deleted is left as `.stale.<pid>` debris: the LOCK
# NAME is free either way, which is the only thing that matters for correctness.
claim_stale() { # <judged-pid> <message>
  # a UNIQUE scratch name per attempt: a repeated reclaim inside one loop would otherwise `mv` the
  # second lock INTO the debris the first left behind (mv-into-existing-dir), silently disarming a peer.
  local judged="$1" gone="$LOCKDIR.stale.$$.$RANDOM" got=""
  [ -n "$2" ] && warn "$2"
  mv "$LOCKDIR" "$gone" 2>/dev/null || return 1
  [ -f "$gone/pid" ] && got="$(command cat "$gone/pid" 2>/dev/null)"
  case "$got" in ''|*[!0-9]*) got="" ;; esac
  if [ "$got" = "$judged" ]; then
    rm -rf "$gone" 2>/dev/null || :
    return 0
  fi
  if [ ! -e "$LOCKDIR" ] && mv "$gone" "$LOCKDIR" 2>/dev/null; then
    warn "  · $LOCKDIR was re-created while being reclaimed — restored, not removed."
  else
    warn "  · $LOCKDIR was re-created while being reclaimed — leaving $gone in place rather than deleting a live lock."
  fi
  return 1
}

# ⛔ A PROBE THAT CANNOT ANSWER IS NOT EVIDENCE. `ps -p <missing>` and `ps -p <live-but-invisible>`
# are BYTE-IDENTICAL (exit 1, no output), so a `ps` that is absent — or that cannot SEE the pid (a
# PID-namespaced view of a shared registry, fork pressure) — must not be read as "the holder is dead".
# That is round 1's EPERM defect moved from permission to VISIBILITY, and it was measured stealing a
# LIVE holder's lock on the first failed probe. Where /proc exists, absence there is PROOF; where it
# does not (stock macOS) the answer is UNKNOWN, and only the elapsed-time ceiling may break the lock.
pid_state() { # <pid> → alive | gone | unknown
  local p="$1"
  if command -v ps >/dev/null 2>&1 && ps -p "$p" >/dev/null 2>&1; then printf 'alive'; return 0; fi
  if [ -d /proc/1 ]; then
    if [ -d "/proc/$p" ]; then printf 'alive'; else printf 'gone'; fi
    return 0
  fi
  printf 'unknown'
}

reg_lock() { # 0 = held, 1 = could not serialise (the caller must NOT write)
  local i=0 pidf pid age state
  [ -d "$REG_DIR" ] || mkdir -p "$REG_DIR" 2>/dev/null || return 1
  LOCKDIR="$REG_DIR/.registry-sync.lock"
  LOCK_OWNED=0
  while [ "$i" -lt 50 ]; do
    if mkdir "$LOCKDIR" 2>/dev/null; then
      printf '%s\n' "$$" > "$LOCKDIR/pid" 2>/dev/null || :
      LOCK_OWNED=1
      return 0
    fi
    pidf="$LOCKDIR/pid"; pid=""
    [ -f "$pidf" ] && pid="$(command cat "$pidf" 2>/dev/null)"
    case "$pid" in ''|*[!0-9]*) pid="" ;; esac
    age="$(lock_age "$LOCKDIR")"
    # ⛔ WHICH AMBIGUITY EACH ARM MAY RESOLVE (#2510 review rounds 1-4, every one measured):
    #  · a recorded pid the OS proves GONE is UNAMBIGUOUS, so a short grace is enough;
    #  · every OTHER shape is AMBIGUOUS and only elapsed time may break it — an absent pid (a live
    #    acquirer is pid-less for the microseconds between `mkdir` and the write: a 2 s grace STOLE one
    #    that was descheduled for 3 s), an unreadable pid, a pid that is ALIVE (a frozen holder, or a
    #    pid the OS recycled onto an unrelated process), and a probe that cannot answer (`ps` absent
    #    or blind, where /proc cannot corroborate). Time must outlive the run's own bound, which is
    #    why the ceiling is derived from MAX_WAIT;
    #  · a lock we cannot DATE is never reclaimed: fail closed, wait out the bound, and let the caller
    #    refuse to write — the same doctrine as the strict-parse fallback in `_field_json`.
    state="none"
    [ -n "$pid" ] && state="$(pid_state "$pid")"
    if [ -z "$age" ]; then
      : # undateable ⇒ cannot prove abandoned ⇒ never steal it
    elif [ "$state" = "gone" ] && [ "$age" -ge "$LOCK_PID_GRACE" ]; then
      claim_stale "$pid" "  ⚠️ reclaiming $LOCKDIR — its holder (pid $pid) is gone (a killed run)." || :
    elif [ "$age" -ge "$LOCK_STALE_MAX" ]; then
      if [ -n "$pid" ]; then
        claim_stale "$pid" "  ⚠️ reclaiming $LOCKDIR — still names pid $pid after ${age}s, longer than any sync run holds it." || :
      else
        claim_stale "" "  ⚠️ reclaiming $LOCKDIR — no usable pid after ${age}s (its holder died before it could record itself)." || :
      fi
    fi
    sleep 0.1; i=$((i + 1))
  done
  return 1
}
reg_unlock() {
  # ⛔ RELEASE ONLY WHAT WE STILL OWN. The ceiling arm can reclaim a lock that still names a LIVE pid,
  # so this process may reach here long after it lost the lock; removing unconditionally then deletes
  # the NEW holder's lock and lets a third run in mid-critical-section (measured). An unreadable pid is
  # NOT a licence to remove either — it cannot prove ownership, and the 2 s grace reclaims it anyway.
  local mine=""
  if [ "${LOCK_OWNED:-0}" = "1" ] && [ -n "${LOCKDIR:-}" ] && [ -f "$LOCKDIR/pid" ]; then
    mine="$(command cat "$LOCKDIR/pid" 2>/dev/null)"
    case "$mine" in ''|*[!0-9]*) mine="" ;; esac
    [ "$mine" = "$$" ] && rm -rf "$LOCKDIR" 2>/dev/null
  fi
  LOCK_OWNED=0; LOCKDIR=""
  return 0
}

PUSHED=0 SKIPPED_OLDER=0 SAME=0 WROTE=0 CONFLICT=0 UNKEYED=0 UNREADABLE=0 LOCAL_UNUSABLE=0 FAILED=0 PUSH_FAILED=0 UNCHANGED=0
LOCKDIR=""
LOCK_OWNED=0
# ── ONE listing per run (agent-infra#3180) ───────────────────────────────────────────────────────
# `union` = `do_pull` then `do_push`, and both called `fetch_refs` — 4 git network calls to read the
# SAME namespace twice (measured: ls-remote 2.4-3.9 s + fetch 3.7 s, so ~10-15 s of a land bought
# nothing). `fetch_once` memoizes the first listing for the rest of the call.
# ⛔ IT MUST NOT MEMOIZE THE RETRY. `push_one` re-lists deliberately before re-deciding: a refusal
# means a peer moved the ref, and re-deciding from the STALE listing would compare against the state
# the attempt just lost and be refused again, forever. So the retry calls `refresh_listing`, which
# drops the memo and does a REAL fetch.
FETCHED=0
fetch_once() {
  [ "$FETCHED" -eq 1 ] && return 0
  fetch_refs || return 1
  FETCHED=1
  # any batch keyed on the listing is now stale
  [ -n "$TMPD" ] && rm -f "$TMPD/store.tsv" "$TMPD/store.blobs" "$TMPD/store.keys"
  return 0
}
refresh_listing() {
  FETCHED=0
  fetch_refs >/dev/null 2>&1
}
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
    refresh_listing
  done
  warn "  ⚠️ FAILED $key — the push was refused twice (a peer moved the ref, or this box cannot push to $REMOTE). The record stays LOCAL and is not lost; re-run to retry."
  FAILED=$((FAILED + 1)); PUSH_FAILED=$((PUSH_FAILED + 1)); return 0
}

pull_one() { # <key>
  # The lock covers the COMPARE and the WRITE (see reg_lock). The wrapper exists so every one of
  # pull_one_locked's early returns releases it — a lock leaked on an early return would wedge the
  # next run, which is a worse failure than the race it prevents.
  if ! reg_lock; then
    warn "  ⚠️ skip $1 — could not serialise the registry (another run holds $REG_DIR/.registry-sync.lock);"
    warn "     NOTHING was written, so no record was overwritten with an older one. Re-run to retry."
    FAILED=$((FAILED + 1)); return 0
  fi
  pull_one_locked "$1"
  local rc=$?
  reg_unlock
  return "$rc"
}

pull_one_locked() { # <key>
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
  # ⛔ USABILITY BEFORE ORDERING, AND BEFORE ANY FIELD READ. A record the rail cannot read must
  # never win the comparison: it would replace a usable local record with bytes `read_record`
  # refuses (see `record_usable`). It is checked FIRST because `field` is now the READER'S parse: a
  # record that is not strict JSON has no readable `reviewed_at` either, so the ordering arm below
  # would report "no readable reviewed_at" for a file whose real defect is that it is UNUSABLE — a
  # less accurate reason for the same skip, and the one §19 pins.
  if ! record_usable "$tmp"; then
    warn "  ⚠️ skip $key — the peer's record is not one this box's rail can USE (no 40-hex head_sha, no verdict, or not strict JSON); refusing to install it over $(if local_record_for_key "$key" >/dev/null 2>&1; then echo 'the local record'; else echo 'nothing'; fi)."
    rm -f "$tmp"; UNREADABLE=$((UNREADABLE + 1)); return 0
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
      # ⛔ A local record that is NEWER but that this box's own reader cannot USE wins the
      # comparison for ever, and `pull` is named as the remedy on the very refusal it causes
      # (atomic-land.sh's "no review record" message) — so a lane was told to run a verb that can
      # never help. Rule 1 is NOT relaxed (the newer bytes are not overwritten); what changes is
      # that the run NAMES the real state and the real remedy instead of reporting a
      # converged-looking `keep` (#2510 P2).
      if ! record_usable "$lf"; then
        warn "  ⚠️ skip $key — this box's record is NEWER ($lat > $rat) but is NOT one its own rail can use"
        warn "     (no 40-hex head_sha, no verdict, or not strict JSON). It is NOT overwritten (#2374 rule 1)"
        warn "     and \`pull\` cannot repair it — remove or re-mint $lf, or the lane keeps reading the older one."
        # ⛔ ITS OWN COUNTER. The rc-4 summary (and `atomic-land.sh`'s rc-4 arm) says "the STORE holds
        # records this box cannot use" — which is a FLEET-facing claim, and it is false here: the
        # unusable bytes are on this box, in this box's own file. Sharing `UNREADABLE` sent the
        # operator to the store side, which is the misdirection this arm was added to remove (round 4).
        UNREADABLE=$((UNREADABLE + 1)); LOCAL_UNUSABLE=$((LOCAL_UNUSABLE + 1)); rm -f "$tmp"; return 0
      fi
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

# ── THE CONVERGED PRE-PASS (agent-infra#3180) ──────────────────────────────────────────────
# THE MEASURED PROBLEM. Every land runs `union`, and `union` examined all 4,027 records ONE AT A
# TIME with ~10 process spawns each — `store_oid`'s awk re-scanning the whole listing, `git show`,
# 3-8 `field` seds, a `python3`, a `mktemp` — on records whose bytes were ALREADY IDENTICAL on both
# sides. Measured on the hub box: 0.37 s/record for the pull half and 0.25 s for the push half, i.e.
# tens of minutes of local CPU before a land does anything useful. The network was never the problem
# (`union` makes 4 git calls, two of them redundant).
#
# WHAT THIS DOES. A record's identity IS its bytes. The store's own listing names, per ref, the
# commit whose tree carries `record.json`; ONE `git cat-file --batch-check` resolves all of them to
# blob OIDs, and ONE `git hash-object --stdin-paths` hashes every local file. A pair whose OIDs are
# equal is byte-identical, so it is already converged and needs none of the per-record machinery.
# Every other pair takes the ORIGINAL path, unchanged — all four #2374 merge rules, `record_usable`,
# the key-vs-record identity test, the exit 3/4 accounting.
#
# ⛔ IT IS NOT A CACHE, and the distinction is the point. The file's header rejects a cache of "what
# it has already pushed" because a stale cache SILENTLY SKIPS a newer record. Nothing here is
# remembered between runs: each run re-reads the store's own listing and re-hashes the local files,
# so a record that changed on either side cannot be skipped. The cost is paid in O(1) processes plus
# O(n) in-process comparisons, instead of O(n) process spawns.
#
# ⛔ THE SKIP CANNOT OUT-VOTE TODAY'S CHECKS: a byte-identical pair is short-circuited only after
# the REAL `field` passes `pull_one`'s own value tests (non-empty `reviewed_at`, numeric `pr`,
# non-empty `repo`, and `<owner>-<repo>-<pr> == key`) and — for the pull half — `record_usable`'s own
# JSON rules via ONE `python3` process (a dict, a 40-hex `head_sha`, a non-empty `verdict`). Any doubt
# falls through to the full path, so `unreadable`/`unkeyed`/conflict accounting is preserved exactly.
TMPD=""
sync_scratch() { # create the run's scratch dir once; 0 on success
  [ -n "$TMPD" ] && return 0
  TMPD="$(mktemp -d "${TMPDIR:-/tmp}/registry-sync.XXXXXX" 2>/dev/null)" || TMPD=""
  [ -n "$TMPD" ]
}
# `--quiet` is used by callers that CAPTURE this verb's output (cloud-cell-doctor runs
# `union --quiet` and takes the first non-`union:` line as the reason it did not converge), so a
# heartbeat printed under `--quiet` would become that caller's diagnosis. Progress honours it.
progress() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*" >&2; }

# The store's refs as `key<TAB>oid`, sorted by KEY (`LC_ALL=C`) so everything downstream can merge-join.
store_sorted() { # <out>
  printf '%s\n' "$STORE_REFS" | awk 'NF >= 2 { k=$2; sub(/^refs\/reviews\//, "", k); print k "\t" $1 }' \
    | LC_ALL=C sort > "$1"
}
store_key_list() { # <store-sorted> <out>  — just the keys
  command cut -f1 "$1" > "$2"
}

# `key<TAB>bloboid` for every store ref, ONE git process for all of them. An oid that cannot be
# resolved here is EMPTY, never "equal": `<expr> missing` is a well-formed reply line (a count guard
# alone would pass over it), so field 2 must be `blob` and field 1 must be 40 hex or the key cannot
# possibly match a local file and takes the full path.
store_blob_map() { # <store-sorted> <out> → 0 ok, 1 unusable (caller falls back to the full path)
  local list="$1" out="$2" q="$TMPD/q" r="$TMPD/r" lr="$TMPD/lr" nq nr
  [ -f "$out" ] && return 0
  : > "$q"; : > "$lr"
  # ⛔ THE BATCH IS PASTED BACK AGAINST THE ROWS IT WAS BUILT FROM, so both must be the SAME rows. A
  # row with no oid has no query, and skipping it in the query loop alone (`[ -n "$oid" ] ||
  # continue`) left `$list` one line longer than the replies — `paste` then paired every key from
  # that row onward with the PREVIOUS record's objectname, producing `key<TAB>wrongblob`. A wrong
  # blob that happens to equal a local file's OID SKIPS a pair that is not converged (a pull/push
  # silently dropped), which is precisely what the guard four lines below exists to prevent and
  # could not see. Dropping the row from both sides here makes the alignment structural.
  command awk -F'\t' -v lr="$lr" -v q="$q" '
    NF >= 2 && $2 != "" { print $1 "\t" $2 > lr; print $2 ":record.json" > q }
  ' "$list"
  nq="$(command wc -l < "$q" | tr -d ' ')"
  git_b cat-file --batch-check='%(objectname) %(objecttype)' < "$q" > "$r" 2>/dev/null || return 1
  nr="$(command wc -l < "$r" | tr -d ' ')"
  # WITHIN this batch the reply is one line per query: a short or long reply pairs keys with OTHER
  # records' oids, and a wrong pairing is a wrong `same`. Discard the whole map, not one line.
  [ "$nq" = "$nr" ] || return 1
  paste "$lr" "$r" | awk -F'\t' 'BEGIN{OFS="\t"} {
      n = split($3, a, " ")
      blob = (n >= 2 && a[2] == "blob" && length(a[1]) == 40) ? a[1] : ""
      print $1, blob
    }' > "$out"
  return 0
}

# `key<TAB>path<TAB>bloboid` for a `key<TAB>path` list, ONE git process for all of them.
# ⛔ `git hash-object --stdin-paths` ABORTS at the first unreadable path and emits only a PREFIX of
# the hashes, so the count check below is load-bearing, not decoration.
hash_pairs() { # <key<TAB>path file> <out>
  local pairs="$1" out="$2" paths="$TMPD/paths" oids="$TMPD/oids" np no
  : > "$out"
  [ -s "$pairs" ] || return 0
  command cut -f2 "$pairs" > "$paths"
  np="$(command wc -l < "$paths" | tr -d ' ')"
  git_b hash-object --stdin-paths < "$paths" > "$oids" 2>/dev/null || return 1
  no="$(command wc -l < "$oids" | tr -d ' ')"
  [ "$np" = "$no" ] || return 1
  paste "$pairs" "$oids" > "$out"
  return 0
}

# The pairs whose bytes are identical on both sides, KEY-INDEXED (never by line position — the two
# sides legitimately have different lengths: 4,027 store refs vs 4,023 local files on the hub box).
# A key present on one side only is simply not paired, so it takes the full path.
identical_pairs() { # <store-blob-map> <hashed-pairs> <out> → 0 ok, 1 could not be computed
  local map="$1" hashed="$2" out="$3" sm="$TMPD/sorted-map" sp="$TMPD/sorted-pairs" jn="$TMPD/joined"
  : > "$out"
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$map" > "$sm"
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$hashed" > "$sp"
  # ⛔ `join` COMPARES UNDER THE AMBIENT LOCALE, so it must be pinned to the collation its inputs
  # were sorted with. Both `sort`s above are `LC_ALL=C`; an unqualified `join` merges under the
  # ambient locale instead, and on a mixed-case key set (`Zeta-…` sorts before `alpha-…` in C and
  # after it under en_US) its order check disagrees with the inputs: measured on coreutils 9.4,
  # `join --check-order` reports "input is not in sorted order", exits 1 and emits only a PREFIX of
  # the pairs. One such key anywhere in a 4,027-key store is then enough to make the whole pre-pass
  # degrade — every record back to ~21 spawns apiece, i.e. the 26-minute land #3180 removes — and
  # the old `return 0` made that a SILENT no-op. So: pin the collation, and report the failure so
  # the caller can say it fell back instead of pretending it converged.
  LC_ALL=C join -t "$(printf '\t')" -1 1 -2 1 "$sm" "$sp" > "$jn" || return 1
  awk -F'\t' '$2 != "" && $2 == $4 { print $1 "\t" $3 }' "$jn" > "$out"
  return 0
}

# `record_usable`'s OWN rules, applied to a whole candidate list in ONE process (a per-record python3
# measured 69-88 ms, which is most of the old cost). No value extraction happens here: `repo`/`pr`/
# `reviewed_at` are read by `field` in bash, exactly as `pull_one` reads them.
usable_pairs() { # <key<TAB>path file> <out key list> → 0 ok
  local pairs="$1" out="$2"
  : > "$out"
  command -v python3 >/dev/null 2>&1 || return 1
  python3 - "$pairs" "$out" <<'PY' || return 1
import json, re, sys
pairs, out = sys.argv[1], sys.argv[2]
keep = []
with open(pairs) as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        key, _, path = line.partition("\t")
        try:
            with open(path, "rb") as f:
                d = json.load(f)
        except Exception:
            continue
        if not isinstance(d, dict):
            continue
        h, v = d.get("head_sha", ""), d.get("verdict", "")
        if not (isinstance(h, str) and re.fullmatch(r"[0-9a-fA-F]{40}", h)):
            continue
        if not (isinstance(v, str) and v.strip()):
            continue
        keep.append(key)
with open(out, "w") as fh:
    for k in keep:
        fh.write(k + "\n")
PY
  return 0
}

# pull's view: the key is the unit, and the file is the one `read_record` would act on.
converged_pull() { # <store-sorted> <out key list>
  local list="$1" out="$2" cand="$TMPD/pull.cand" map="$TMPD/store.blobs" hashed="$TMPD/pull.hashed"
  local ident="$TMPD/pull.ident" same="$TMPD/pull.samefields" k path
  : > "$out"; : > "$cand"; : > "$hashed"; : > "$same"
  store_blob_map "$list" "$map" || return 1
  while IFS=$'\t' read -r k _; do
    [ -n "$k" ] || continue
    path="$(local_record_for_key "$k")" || continue
    [ -n "$path" ] && [ -f "$path" ] || continue
    printf '%s\t%s\n' "$k" "$path" >> "$cand"
  done < "$list"
  hash_pairs "$cand" "$hashed" || return 1
  identical_pairs "$map" "$hashed" "$ident" || return 1   # could not be computed ≠ nothing identical
  # `pull_one`'s own value tests, with the real `field` (spawn-free since #3180).
  while IFS=$'\t' read -r k path; do
    [ -n "$k" ] || continue
    local rat repo pr
    rat="$(field "$path" reviewed_at)"
    [ -n "$rat" ] || continue
    pr="$(field "$path" pr)"
    case "$pr" in ''|*[!0-9]*) continue ;; esac
    repo="$(field "$path" repo)"
    [ -n "$repo" ] || continue
    [ "${repo%/*}-${repo#*/}-$pr" = "$k" ] || continue
    printf '%s\t%s\n' "$k" "$path" >> "$same"
  done < "$ident"
  # `record_usable`'s rule, batched. A missing/broken python3 leaves the list EMPTY (nothing is
  # skipped), which is today's behaviour and today's warning.
  usable_pairs "$same" "$out" || : > "$out"
  return 0
}

do_pull() {
  fetch_once || return 1
  local total=0 conv=0 changed=0 examined=0 key store_sorted_f keys same_f changed_f
  if ! sync_scratch; then
    progress "registry-sync: pull — no scratch dir; examining every record (no pre-pass)"
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      pull_one "$key"
    done <<<"$(remote_refs)"
    return 0
  fi
  store_sorted_f="$TMPD/store.tsv"; keys="$TMPD/store.keys"
  same_f="$TMPD/pull.converged"; changed_f="$TMPD/pull.changed"
  store_sorted "$store_sorted_f"
  store_key_list "$store_sorted_f" "$keys"
  total="$(command wc -l < "$keys" | tr -d ' ')"
  : > "$same_f"; : > "$changed_f"
  if converged_pull "$store_sorted_f" "$same_f"; then
    conv="$(command wc -l < "$same_f" | tr -d ' ')"
    SAME=$((SAME + conv))
    UNCHANGED=$((UNCHANGED + conv))
    LC_ALL=C sort "$same_f" > "$TMPD/pull.converged.sorted"
    LC_ALL=C comm -23 "$keys" "$TMPD/pull.converged.sorted" > "$changed_f"
  else
    progress "registry-sync: pull — the converged pre-pass could not run; examining all $total records"
    command cat "$keys" > "$changed_f"
  fi
  changed="$(command wc -l < "$changed_f" | tr -d ' ')"
  progress "registry-sync: pull — $total record(s) in the store, $conv already identical, $changed to examine"
  [ "$changed" -eq 0 ] && progress "registry-sync: nothing to sync — every record is already identical on both sides"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    examined=$((examined + 1))
    [ $((examined % 25)) -eq 0 ] && progress "registry-sync: pull progress $examined/$changed"
    pull_one "$key"
  done < "$changed_f"
  return 0
}

do_push() {
  fetch_once || return 1
  local key name list conv=0 changed=0 examined=0 total=0 map="" report=""
  local changed_f keyedcf list_sort
  list="$(mktemp "${TMPDIR:-/tmp}/registry-sync-keys.XXXXXX")" || return 1
  local_keyed "$list" <<<"$(registry_names)"
  total="$(command wc -l < "$list" | tr -d ' ')"
  if ! sync_scratch; then
    while IFS=$'\t' read -r key name; do
      [ -n "$key" ] || continue
      push_one "$key" "$REG_DIR/${name:-$key.json}"
    done < "$list"
    rm -f "$list"
    return 0
  fi
  changed_f="$TMPD/push.changed"; keyedcf="$TMPD/push.keyed"; list_sort="$TMPD/push.keyed.sorted"
  : > "$changed_f"; : > "$keyedcf"
  # `local_keyed` emits `key<TAB>filename` — the PAIR is the push unit, not the key: a qualified
  # record and a newer legacy `<pr>.json` legitimately share a key, and skipping by key alone would
  # suppress the newer one's publication.
  while IFS=$'\t' read -r key name; do
    [ -n "$key" ] || continue
    printf '%s\t%s/%s\n' "$key" "$REG_DIR" "${name:-$key.json}" >> "$keyedcf"
  done < "$list"
  LC_ALL=C sort -t "$(printf '\t')" -k1,1 "$keyedcf" > "$list_sort"
  # The store's blob map is the pull half's product under `union`; a standalone `push` computes it.
  if [ ! -f "$TMPD/store.blobs" ]; then
    store_sorted "$TMPD/store.tsv"
    store_blob_map "$TMPD/store.tsv" "$TMPD/store.blobs" || : > "$TMPD/store.blobs"
  fi
  map="$TMPD/store.blobs"
  if [ -s "$map" ] && hash_pairs "$keyedcf" "$TMPD/push.hashed" 2>/dev/null; then
    if ! identical_pairs "$map" "$TMPD/push.hashed" "$TMPD/push.ident"; then
      progress "registry-sync: push — the converged pre-pass could not run; examining all $total records"
      : > "$TMPD/push.ident"
    fi
    # `push_one` refuses a record with no readable `reviewed_at` BEFORE any comparison, so a
    # byte-identical record may NOT be skipped when that field is empty.
    : > "$TMPD/push.stamp"
    while IFS=$'\t' read -r key name; do
      [ -n "$key" ] || continue
      [ -n "$(field "$name" reviewed_at)" ] && printf '%s\t%s\n' "$key" "$name" >> "$TMPD/push.stamp"
    done < "$TMPD/push.ident"
    conv="$(command wc -l < "$TMPD/push.stamp" | tr -d ' ')"
    SAME=$((SAME + conv))
    UNCHANGED=$((UNCHANGED + conv))
    # (key, PATH) is the set identity: a second file for a converged key is still examined.
    # ⛔ `NR == FNR` FAILS ON AN EMPTY FIRST FILE (the second file's first line would be taken as the
    # first file's), which silently dropped every local record from `changed` — a record the store
    # does not hold yet was then never published. Guard the empty case explicitly.
    if [ -s "$TMPD/push.stamp" ]; then
      awk -F'\t' 'NR == FNR { keep[$1 "\t" $2] = 1; next } !(($1 "\t" $2) in keep)' \
        "$TMPD/push.stamp" "$list_sort" > "$changed_f"
    else
      command cat "$list_sort" > "$changed_f"
    fi
  else
    progress "registry-sync: push — the converged pre-pass could not run; examining all $total records"
    command cat "$list_sort" > "$changed_f"
  fi
  changed="$(command wc -l < "$changed_f" | tr -d ' ')"
  progress "registry-sync: push — $total local record(s), $conv already identical, $changed to examine"
  [ "$changed" -eq 0 ] && progress "registry-sync: nothing to sync — every local record is already in the store"
  while IFS=$'\t' read -r key name; do
    [ -n "$key" ] || continue
    examined=$((examined + 1))
    [ $((examined % 25)) -eq 0 ] && progress "registry-sync: push progress $examined/$changed"
    push_one "$key" "$name"
  done < "$changed_f"
  rm -f "$list"
  return 0
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
  local key name at list atfile lnew="" rnew="" local_n=0 remote_n=0 missing=0
  list="$(mktemp "${TMPDIR:-/tmp}/registry-sync-status.XXXXXX")" || return 1
  atfile="$(mktemp "${TMPDIR:-/tmp}/registry-sync-status-at.XXXXXX")" || { rm -f "$list"; return 1; }
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    remote_n=$((remote_n + 1))
    # ⛔ THE SAME PARSE AS EVERY OTHER VERB. This was the THIRD one — a greedy `sed`, i.e. exactly the
    # last-match read this file exists to delete — so `status` reported the NESTED `reviewed_at` of a
    # record carrying an object (`origin newest_reviewed_at=2000-…` for a record whose top level says
    # `2026-…`, measured). `field()` is the reader's parse; `remote_record` goes through a file so it
    # can be read by the same function the compare uses.
    remote_record "$key" > "$atfile" 2>/dev/null
    at="$(field "$atfile" reviewed_at)"
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
  rm -f "$list" "$atfile"
  printf 'local  records=%s newest_reviewed_at=%s hash=%s\n' "$local_n" "${lnew:-none}" "$(registry_hash)"
  printf 'origin records=%s newest_reviewed_at=%s\n' "$remote_n" "${rnew:-none}"
  printf 'missing_here=%s\n' "$missing"
  return 0
}

summary() { # <verb>
  printf '%s: wrote=%s pushed=%s same=%s older_refused=%s conflicts=%s unkeyed=%s unreadable=%s failed=%s unchanged=%s\n' \
    "$1" "$WROTE" "$PUSHED" "$SAME" "$SKIPPED_OLDER" "$CONFLICT" "$UNKEYED" "$UNREADABLE" "$FAILED" "$UNCHANGED"
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
    if [ "$LOCAL_UNUSABLE" -gt 0 ] && [ "$LOCAL_UNUSABLE" -eq "$UNREADABLE" ]; then
      warn "registry-sync.sh: $UNREADABLE record(s) were SKIPPED — but they are THIS BOX's OWN unusable"
      warn "  record(s), NOT a store-side defect: no record in the store was refused. Remove or re-mint them"
      warn "  here; nothing was overwritten."
    else
      warn "registry-sync.sh: $UNREADABLE record(s) were SKIPPED because they could not be read or ordered — this is"
      warn "  NOT a converged state (the store holds records this box cannot use). Nothing was overwritten."
    fi
    return 4
  fi
  return 0
}

resolve_store || exit 1
# The run's scratch (the converged pre-pass's batches) is removed on EVERY exit path, including the
# `exit 1` arms below — a land must not leave debris behind on a box whose disk is the constraint.
cleanup_scratch() { [ -n "$TMPD" ] && rm -rf "$TMPD" 2>/dev/null; TMPD=""; }
trap cleanup_scratch EXIT
case "$VERB" in
  pull)   do_pull  || exit 1; summary pull;  exit $? ;;
  push)   do_push  || exit 1; summary push;  exit $? ;;
  union)  do_pull  || exit 1; do_push || exit 1; summary union; exit $? ;;
  status) do_status || exit 1; exit 0 ;;
esac
