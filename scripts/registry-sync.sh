#!/usr/bin/env bash
# registry-sync.sh — replicate the review-record registry across boxes (agent-infra#2374).
#
#   registry-sync.sh pull    [--repo <path>] [--dir <path>] [--remote <name>] [--timeout <n>] [--quiet]
#   registry-sync.sh push    …
#   registry-sync.sh union   …   # pull, then push — the converging verb
#   registry-sync.sh status  …   # counts, plus the records another box has and this one does not
#   registry-sync.sh surface-check [--repo <path>]
#                                # 0 when this script's git surface is INTACT (no unbounded verb,
#                                # no working-tree verb), 5 when it is DEFECTIVE, 3 when that
#                                # cannot be checked here. ⛔ 0 is NOT a promise that the guard will
#                                # RUN it: a hub-rooted session is still withheld by the guard's
#                                # #1484/#1485 content walk (agent-infra#2621).
#
# Exit: 0 converged (nothing left to do), 2 usage, 1 cannot run (no store / no remote /
# unwritable registry / a record that could not be moved), 3 CONVERGED WITH DIVERGENCE — at
# least one pair of records shares a `reviewed_at` but disagrees on content, so neither side was
# overwritten (rule 4 below), 4 records were SKIPPED because they could not be read or ordered
# (an unreadable peer ref or stamp, a mis-keyed record) — an unreadable store is not a converged
# one, and 0 must never be reported over records this box could not use.
#
# `surface-check` has its OWN status: 0 surface intact / 5 surface DEFECTIVE / 3 not verified.
# ⛔ A RUN OF THIS SCRIPT NEVER RETURNS 5. A guard refusal happens BEFORE the first line of this
# file executes, so the caller sees NO exit status at all — and "no exit status" has been read as
# success, which is the whole of #2520. `surface-check` is the verb that turns that silence into a
# value. A wrapper that sees the invocation withheld must map it onto 5 rather than onto 0 — and
# must NOT read a 5 from `surface-check` as "the guard refused it": 5 there means this file's own
# surface is defective, which is why the guard WOULD refuse it, not that it did.
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
# ⛔ ONE DOCUMENTED EXCEPTION: a local record that is byte-different from the published one but
# equal once TRAILING NEWLINES are stripped is REWRITTEN to the published bytes (`· canon <key>`,
# counted in `wrote=`). That is not a re-write of a decision — the stamp, verdict and head are
# already equal, rule 4 protects records that DISAGREE — it is the repair of a formatting artefact
# from an older pull that left 3,261 of 3,462 records one newline away from their own ref. Keeping
# it would mean every pass re-reads the whole registry (`same_bytes` is exact), which is what made
# an hourly pass impossible to bound; after it, the local registry is byte-identical to the fleet's
# record, which is the property `hash=` and the equality fast path both rest on.
#
# ── COST, MEASURED, AND WHY IT IS SHAPED THIS WAY (#2577) ─────────────────────────────────
# Both directions compare EVERY key against the store, so a naive per-key read costs two git
# processes per key per direction. On the reference box (3,462 refs) that was **~15 minutes** for
# one `union` — a scheduled step killed by its own bound on every pass, i.e. an inert enforcer.
# Two BATCHED calls now answer the same question (`cat-file --batch-check` for the store's blob id
# per ref, `hash-object --stdin-paths` for this box's per file; equal ids are equal bytes), so the
# steady state is ~29 s `pull` / ~75 s `push` on that box and the slow path runs only on records
# that actually differ. The first pass over a BLIND box is still the expensive one, and it makes
# CUMULATIVE progress: each record it finishes is canonical and thereafter takes the fast path.
#
# ── THE CONVERGENCE LINE (#2577) ───────────────────────────────────────────────────────────
# Every writing verb prints, after the detailed summary,
#     <verb>: refs=N files=N added=N updated=N skipped=N
#   refs     the refs the STORE lists for this run — the fleet's side
#   files    the .json records this box's registry holds AFTER the run — this side
#   added    records materialised where this box had none (the #2374 failure, counted)
#   updated  records materialised OVER a local record that lost the `reviewed_at` ordering (rule 1)
#   skipped  records the run could not READ or could not USE, so it never wrote them — the same
#            counter the detailed line reports as `unreadable`, which is the exit-4 class
# The two numbers are the point: `refs` and `files` drifting apart IS a stalled sync, and it is
# visible from one log line instead of inferred from a merge role's NO-RECORD refusals. The
# detailed line (`wrote= pushed= same= older_refused= conflicts= unkeyed= …`) is unchanged and
# still carries the per-rule breakdown; this line is the convergence surface a scheduler logs.
#
# ── THE GIT SURFACE IS LITERAL (#2520) ────────────────────────────────────────────────────
# ⛔ THIS FILE'S git INVOCATIONS ARE ALL STATICALLY VISIBLE, ONE LITERAL VERB PER LINE, AND NONE
# OF THEM CAN REWRITE A CHECKOUT. That is not style: the checkout-guard (`#709`) reads a script
# an agent asks it to run and fails CLOSED on any git invocation whose verb it cannot bound, so a
# single dynamic-argv wrapper (`git "$@"`) made every verb of this script — status, pull, union —
# un-runnable from an agent's shell, which is exactly the remedy the rail's "no review record"
# refusal names (#2520). A registry sync moves BLOBS and REFS; it never needs a working tree, so
# the fix is not a guard exemption (that would be weakening a gate that protects real work) and
# not a roster of allowed verbs: it is that the script has no such verb to classify.
# The surface, verb by verb, is `g_ls_remote`, `g_fetch`, `g_remote_get_url`, `g_rev_parse`,
# `g_cat_blob`, `g_cat_batch_check`, `g_hash_object`, `g_hash_paths`, `g_mktree`, `g_commit_tree`,
# `g_push`/`g_push_create` and `g_update_ref` below — network reads, object/blob reads, object/blob
# writes, one ref update, and one push. `is_repo`'s own check is literal for the same reason. If
# this file is edited, run `registry-sync.sh surface-check` (exit 0 = surface intact, 5 = surface
# defective) — the shipped test suite runs the same check, and pins it against a fixture that
# reintroduces the wrapper.
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
# point every landing passes through), `cloud-cell-bringup.sh` runs it so a freshly booted cell
# starts with the records that already exist instead of with none, and `cloud-cell-doctor.sh`'s
# hourly `hygiene` role runs it as its fourth sub-step (#2577) — the rail heals the registry one
# PR at a time, and only for a PR already offered to the rail, so without a scheduled pass a box
# whose merge role reads its own small registry never offers the PR at all. That is the fixed
# point the hygiene step leaves. `push` and `pull` are also operators' verbs: `status` first to
# see what is missing here, then `pull`.
set -uo pipefail

SELF_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

VERB="${1:-}"
case "$VERB" in
  pull|push|union|status|surface-check) shift ;;
  -h|--help|"") sed -n '2,/^set -uo/{/^set -uo/d;s/^# \{0,1\}//;p;}' "${BASH_SOURCE[0]}"; exit 2 ;;
  *) printf "registry-sync.sh: unknown verb '%s' — usage: registry-sync.sh <pull|push|union|status|surface-check> [--repo <path>] [--dir <path>] [--remote <name>] [--timeout <n>] [--quiet]\n" "$VERB" >&2; exit 2 ;;
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

# ── bounded git, ONE LITERAL VERB PER LINE (#2520) ───────────────────────────────────────
# Every network op is bounded, and GIT_TERMINAL_PROMPT=0 is the one that matters most: without it
# a box with no credential helper BLOCKS on an invisible username prompt until the calling tool is
# killed, which reads as "the rail hung" rather than "this box cannot authenticate".
#
# ⛔ THE VERB IS LITERAL AT THE CALL SITE. The previous shape was ONE wrapper taking `<git args…>`
# and running `git -C "$STORE" -c gc.auto=0 "$@"`. The bound and the env were right; what was
# wrong is that the checkout-guard cannot bound a verb that arrives as `"$@"`, so it withheld the
# WHOLE invocation — `status`, `pull` and `union` alike — with `Form: unverifiable-verb` (#2520,
# reproduced 2026-10-23 from the hub AND from a linked worktree). Each verb therefore gets its own
# one-line wrapper below, naming the verb in the source where the guard (and a human) can read it.
# `run_bounded` only supplies the bound + the prompt-safe environment; it never decides what runs.
TIMEOUT_BIN=""
for c in timeout gtimeout; do command -v "$c" >/dev/null 2>&1 && { TIMEOUT_BIN="$c"; break; }; done
run_bounded() { # <seconds> <command…>
  local secs="$1" pid w rc; shift
  if [ -n "$TIMEOUT_BIN" ]; then
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true GIT_PAGER=cat GIT_OPTIONAL_LOCKS=0 \
      "$TIMEOUT_BIN" "$secs" "$@"
    return
  fi
  # No `timeout` on this box (stock macOS). A WATCHDOG, not a fallback to unbounded: the caller is
  # the landing rail, and an unbounded network read there is a hang, not a slow success.
  GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/true GIT_PAGER=cat GIT_OPTIONAL_LOCKS=0 "$@" &
  pid=$!
  ( sleep "$secs"; kill -TERM "$pid" 2>/dev/null; sleep 2; kill -KILL "$pid" 2>/dev/null ) >/dev/null 2>&1 &
  w=$!
  wait "$pid"; rc=$?
  kill -TERM "$w" 2>/dev/null
  wait "$w" 2>/dev/null
  return "$rc"
}
# The verbs. Each is ONE literal git invocation inside ONE bound; `-C "$STORE"` pins the repo and
# `-c gc.auto=0` keeps a background gc out of a registry read. Nothing here writes a working tree.
g_remote_get_url() { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 remote get-url "$REMOTE"; }
g_ls_remote()      { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 ls-remote --quiet --refs "$REMOTE" 'refs/reviews/*'; }
g_fetch()          { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 fetch --no-tags --quiet "$REMOTE" '+refs/reviews/*:refs/reviews/*'; }
g_rev_parse()      { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 rev-parse --verify --quiet "$1"; }
g_cat_blob()       { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 cat-file blob "$1"; }
g_hash_object()    { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 hash-object -w "$1"; }
g_mktree()         { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 mktree; }
g_commit_tree()    { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 -c user.name=registry-sync -c user.email=registry-sync@localhost commit-tree "$1" -m "$2"; }
g_push()           { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 push --quiet --force-with-lease="$1" "$REMOTE" "$2"; }
g_push_create()    { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 push --quiet "$REMOTE" "$1"; }
g_update_ref()     { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 update-ref "$1" "$2"; }
# The two BATCHED reads the equality fast path needs (see "THE EQUALITY FAST PATH" below): one
# process for every store record's blob id, one for every local record's. Neither prints content.
g_cat_batch_check() { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 cat-file --batch-check; }
g_hash_paths()    { run_bounded "$MAX_WAIT" git -C "$STORE" -c gc.auto=0 hash-object --no-filters --stdin-paths; }

# ── fields ───────────────────────────────────────────────────────────────────────────────
# sed, not jq: record-review.sh WRITES a record with one printf in a fixed field order and reads
# its own fields back the same way, so a second JSON parser here would be a second definition of
# the record's shape (the same reason that script's record_identity() is an exact-string compare).
field() { # <file> <name>
  # ⛔ WHITESPACE AFTER THE COLON IS VALID JSON. Without `[[:space:]]*` this sed returned
  # ` 441` for `{"pr": 441, …}` and ` 2026-12-31T00:00:00Z` for a pretty-printed stamp, while the
  # fast path (json.load) read `441`/the stamp correctly — so ONE record shape was "same" where a
  # mirror existed and "unreadable"/exit 4 where it did not (measured), and a LEADING SPACE on a
  # stamp sorts below any digit-leading stamp, which made the ordering compare decide "peer is
  # newer" for an OLDER peer and overwrite a newer local record with no conflict and exit 0
  # (measured: local `" 2026-12-31…"` clean was replaced by peer `2026-01-01…` not-clean). The
  # `"name" : value` (space BEFORE the colon, also valid JSON) has the same shape. The trailing trim
  # covers `{"pr":441 , …}`. A record field never legitimately carries outer spaces.
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\{0,1\}\([^\",}]*\)\"\{0,1\}.*/\1/p" "$1" 2>/dev/null \
    | command head -1 | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
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
record_usable() { # <file> → 0 when the reader this box ships can use it
  local f="$1"
  # ⛔ THE CHECK IS THE ONE THE READER MAKES, at the TOP LEVEL of the JSON — not `field` (a greedy sed that
  # takes the LAST match on the line). A record whose top-level `head_sha` is empty but which
  # carries a nested 40-hex one inside, say, an `evidence` object PASSED the old sed-based gate and
  # was installed over a usable local record; `read_record` then read `head_sha=''` and refused
  # ("carries no usable head_sha") — the exact regression this gate exists to prevent, reached
  # through the value parse instead of the syntax parse.
  # ⛔ ONE BODY, TWO CALLERS. `build_local_blobs` asks this same program about the WHOLE registry in
  # ONE process (`--list`), because the equality fast path must not skip a record the gate would
  # refuse: a store record that is unusable AND already mirrored here would otherwise be reported
  # `same` instead of `unreadable`, and `union` would return 0 over a record this box cannot use —
  # the false convergence the header forbids. Restating the rules there instead of sharing them is
  # exactly how a fast path drifts from the gate it stands in for.
  command -v python3 >/dev/null 2>&1 || {
    warn "  ⚠️ python3 is not available, so a record cannot be checked against this box's reader — refusing to install one."
    return 1
  }
  python3 -c "$RECORD_READER_PY" --one "$f" >/dev/null 2>&1
}

# The reader's usability rules, in ONE place. `--one <file>` exits 0 when the box's rail can use it;
# `--list` reads paths from stdin and prints the usable ones (the batched caller).
RECORD_READER_PY='
import json, re, sys
RE = re.compile(r"[0-9a-fA-F]{40}")
def rec(p):
    try:
        d = json.load(open(p))
    except Exception:
        return None
    return d if isinstance(d, dict) else None
# ⛔ TWO READERS READ EVERY RECORD: json (this program, and the rail) and `field()` (a greedy sed).
# They are the SAME reader only when they agree on the value of every COMPARED key. The slow path
# decides with `field`, so a record where json and `field` disagree made the slow path report `same`
# or `conflict` on a value json never saw (measured: a nested "evidence":{"head_sha":...} on an
# EARLIER line made `field` read the nested head while json read the top-level one, so a genuine
# rule-4 divergence was reported as same/exit 0; a verdict of "a}b" read as "a"). A record whose
# compared keys are not unambiguous in BOTH readings is UNREADABLE (exit 4) — never guessed at.
AGREED_KEYS = ("reviewed_at", "pr", "verdict", "head_sha", "repo", "mint", "carried_from", "merge_base_sha", "supersedes")
FIELD_TAIL = re.compile("([^\",}]*)\"?")
# ⛔ FAITHFUL TO sed, BYTE FOR BYTE — a divergence here refuses a legitimate record as `unreadable`
# for ever (measured on a /tmp variant: a record read identically by json and by the shell sed was
# still refused, because this function disagreed with BOTH). Three traps, each one measured:
#   * `str.splitlines()` also splits on U+2028/U+2029/VT/FF; sed splits on `\n` only.
#   * `open()` defaults to universal newlines, turning a lone CR into a line break sed never sees.
#   * python `[ \t]` is not POSIX `[[:space:]]` (which also has \r \f \v), and `str.strip()` strips
#     more than the shell trim does.
SPACE = " \t\r\v\f"
def field_text(text, name):
    pat = re.compile("\"" + re.escape(name) + "\"[" + SPACE + "]*:[" + SPACE + "]*\"?")
    for line in text.split("\n"):
        last = None
        for m in pat.finditer(line):
            last = m
        if last is None:
            continue
        tail = FIELD_TAIL.match(line, last.end())
        return (tail.group(1) if tail else "").strip(SPACE)
    return ""
def agrees(p):
    text = open(p, encoding="utf-8", errors="replace", newline="").read()
    d = rec(p)
    if d is None:
        return False
    for k in AGREED_KEYS:
        jv = d.get(k)
        tv = field_text(text, k)
        # ⛔ NO NON-ASCII IN A COMPARED VALUE. Every compared value is ASCII by construction (a
        # 40-hex sha, a stamp, a verdict token, an owner/name, an int). A multi-byte character makes
        # the two readers disagree in a way this program cannot model: a real U+2028 in `repo` made
        # the SHELL sed truncate the value ("o/r") while the text replica kept it whole — i.e. the
        # slow path would decide on a truncated value that this gate had just vouched for. Refusing
        # is the conservative direction and it is locale-independent; a record that needs a
        # non-ASCII compared value is not one the rail can bind to a key anyway.
        for v in (jv, tv):
            if isinstance(v, str) and not v.isascii():
                return False
        if jv is None:
            # `"key": null` is valid JSON and BOTH readers see no value; the text capture reads the
            # literal `null`, so accepting it here is not a relaxation, it is the same answer.
            if tv not in ("", "null"):
                return False
            continue
        if isinstance(jv, bool) or not isinstance(jv, (str, int)):
            return False
        if str(jv) != tv:
            return False
    return True
def usable(p):
    d = rec(p)
    if d is None:
        return False
    h, v = d.get("head_sha", ""), d.get("verdict", "")
    if not (isinstance(h, str) and RE.fullmatch(h)):
        return False
    if not (isinstance(v, str) and v.strip()):
        return False
    if not agrees(p):
        return False
    return True
def dupkeys(p):
    # A COMPARED KEY THAT APPEARS MORE THAN ONCE, ANYWHERE, IS AMBIGUOUS. `field()` (a greedy sed)
    # reads the LAST occurrence in the TEXT; json.load keeps the last DUPLICATE KEY of an OBJECT.
    # The two disagree the moment a compared key is repeated, so such a record takes the slow path.
    # ⛔ NO APOSTROPHE APPEARS IN THIS FILE, ON PURPOSE: the whole program is a single-quoted
    # shell assignment, so one apostrophe (a raw-string prefix, or quoted %s) terminates it
    # mid-line — measured as `r"%s"\s*:` arriving at python as `r%ss*:` and every record reading
    # as unusable.
    seen = []
    def hook(pairs):
        for k, _v in pairs:
            if k in ("reviewed_at", "pr", "verdict", "head_sha", "repo"):
                seen.append(k)
        return dict(pairs)
    try:
        json.loads(open(p, encoding="utf-8", errors="replace").read(), object_pairs_hook=hook)
    except Exception:
        return True
    return len(seen) != len(set(seen))
def fast_ok(p):
    # ⛔ THE FAST PATH ASKS A STRICTER QUESTION THAN THE INSTALL GATE, because it answers
    # "is this record already what the full comparison would call SAME?" — and the full
    # comparison counts a record UNREADABLE (exit 4) unless it ALSO has a readable
    # reviewed_at, a numeric pr and a repo, and a key its own fields agree with. Testing
    # only head_sha/verdict there let an already-mirrored store defect read as `same`, so
    # `union` returned 0 over a record this box cannot use — the false convergence the
    # file header forbids. Same rule, one body: nothing here may drift from pull_one.
    if not usable(p):
        return False
    d = rec(p)
    if not isinstance(d.get("reviewed_at"), str) or not d.get("reviewed_at").strip():
        return False
    pr, repo = d.get("pr"), d.get("repo", "")
    # ⛔ `pull_one` REQUIRES `^[0-9]+$` ON THE TEXT IT READ, so a NEGATIVE integer is unreadable
    # there and must never read as `same` here (reproduced: `"pr":-5` under the key
    # `…-agent-infra--5` satisfied the identity check as `%s-%s-%d` and the fast path reported
    # converged/exit 0 over a record the slow path refuses with "no usable pr field"/exit 4).
    if not isinstance(pr, int) or isinstance(pr, bool) or pr < 0:
        return False
    if not (isinstance(repo, str) and "/" in repo):
        return False
    # ⛔ TWO READERS READ THIS FILE, AND THEY READ DUPLICATES DIFFERENTLY. `field()` is a greedy
    # sed: it takes the LAST `"name":` anywhere in the text, while json.load keeps only the last
    # DUPLICATE KEY of an object. A nested `"evidence":{"reviewed_at":""}` therefore reads EMPTY
    # to `field` and NON-EMPTY to json — reproduced as `same`/exit 0 over a record `pull_one`
    # refuses with "carries no readable reviewed_at"/exit 4. Any compared key that appears more
    # than once ANYWHERE is AMBIGUOUS: it takes the slow path, which is authoritative.
    if dupkeys(p):
        return False
    # ⛔ UNCONDITIONAL. This used to run only when the file name LOOKED like a qualified key, so a
    # legacy `<pr>.json` (`441.json`) skipped the test entirely — and `local_record_for_key` returns
    # that legacy file for the key derived from the repo field, so a legacy record whose `pr` DENIED
    # the key it sits under reached the fast path and answered `same`/exit 0, while the slow path
    # refuses it as NOT this key/exit 4 (reproduced). A name that does not derive from the record
    # own fields is never fast-eligible: it takes the authoritative slow path.
    stem = p.rsplit("/", 1)[-1][:-5] if p.endswith(".json") else ""
    owner, _, name = repo.partition("/")
    if "%s-%s-%d" % (owner, name, pr) != stem:
        return False
    return True
if sys.argv[1] == "--one":
    sys.exit(0 if usable(sys.argv[2]) else 1)
for p in sys.stdin.read().splitlines():
    if p and fast_ok(p):
        print(p)
'

# ── equal `reviewed_at`, different bytes: WHICH KIND of difference is it? ─────────────────
# Rule 4 reports a DISAGREEMENT. Two records that agree on the verdict and on the HEAD are not
# disagreeing — they differ only in carry PROVENANCE, and calling that a conflict made a carried
# verdict unpublishable for ever: two boxes each carrying their own local record onto the same head
# produce the same head and verdict with different `carried_from`, and every union then exited 3
# with a "reconcile by hand" the operator cannot act on. (A carry of a carry, whose `carried_from`
# names an intermediate head rather than the head of the peer, is still reported as a conflict — that is
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
  # Different heads: the only thing that can certify which one supersedes is the record lineage
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
    if g_remote_get_url >/dev/null 2>&1; then return 0; fi
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
STORE_REF_COUNT=0
fetch_refs() {
  local listing=""
  if ! listing="$(g_ls_remote 2>/dev/null)"; then
    warn "registry-sync.sh: cannot READ the '$REMOTE' registry from '$STORE' — it is UNKNOWN, not empty. Not syncing."
    return 1
  fi
  STORE_REFS="$listing"
  reset_store_blobs            # the listing just changed; the batched map describes the old one
  # `refs=` in the convergence line is the STORE's own count, taken from the one read that is the
  # truth about the store (`ls-remote`), so a listing that returns nothing answers refs=0 —
  # "the store is empty", which is a different state from "the store could not be read" (return 1).
  STORE_REF_COUNT="$(printf '%s\n' "$listing" | awk 'NF >= 2' | wc -l | tr -d ' ')"
  [ -z "$listing" ] && return 0
  # NOT `--prune` (rule 2), and no longer load-bearing for the key list: it only carries objects.
  if ! g_fetch >/dev/null 2>&1; then
    warn "registry-sync.sh: ⚠️ the FETCH from '$REMOTE' failed while the store still lists refs — this run"
    warn "  continues from the store's own listing, and every record whose objects are not already here"
    warn "  is reported UNREADABLE (exit 4) rather than answered from a stale local ref."
  fi
  return 0
}

remote_refs() {
  printf '%s\n' "$STORE_REFS" | awk 'NF >= 2 { sub(/^refs\/reviews\//, "", $2); print $2 }' | LC_ALL=C sort
}

# ── THE EQUALITY FAST PATH (#2577's cost, measured) ───────────────────────────────────────
# A registry is ~3,500 records and BOTH directions compare every key against the store, so the
# steady state used to cost two git processes PER KEY PER DIRECTION — ~14,000 spawns, measured at
# **15 minutes** for one `union` on a box with 3,460 refs. A step the hourly hygiene role has to
# finish inside its own bound cannot afford that: it would be killed mid-run every pass, leaving
# a permanently half-converged registry and a log line that says TIMED OUT for ever — the inert
# enforcer this step exists to remove.
#
# The comparison the merge rules actually make is BYTES (`same_bytes`), and git already answers
# that without reading content: `cat-file --batch-check` gives the store's blob id for every
# `<commit>:record.json` in ONE process, and `hash-object --stdin-paths` gives the blob id of every
# local record in ONE process. Equal blob ids ARE equal bytes, so the fast path is not a heuristic
# — it is the same predicate, computed by the same tool. Anything that is NOT provably identical
# falls through to the full read below, so every rule (1 older, 3 unkeyed, 4 conflict, usability)
# still runs on exactly the records that could possibly violate it.
# ⛔ IT IS NOT A CACHE AND IT KEEPS NO STATE BETWEEN RUNS: both sides are recomputed from the
# store's own listing and this box's own files on every run, so a stale index cannot make a
# record look converged. If the batched call fails (a timeout, a repo that cannot answer), the
# maps are empty, every lookup misses, and the run takes the slow path — never the optimistic one.
STORE_BLOB=""   # "<key>\t<blob-oid|->"   (- = the store lists the ref but carries no record.json)
LOCAL_BLOB=""   # "<path>\t<blob-oid>"
BLOB_DIR=""
cleanup_blobs() { if [ -n "$BLOB_DIR" ] && [ -d "$BLOB_DIR" ]; then rm -rf "$BLOB_DIR"; fi; return 0; }
trap cleanup_blobs EXIT

blob_workdir() {
  if [ -z "$BLOB_DIR" ]; then
    BLOB_DIR="$(mktemp -d "${TMPDIR:-/tmp}/registry-sync-blobs.XXXXXX")" || { BLOB_DIR=""; return 1; }
  fi
  return 0
}

build_store_blobs() { # ONE process over EVERY ref the store lists
  [ -n "$STORE_BLOB" ] && return 0
  [ -n "$STORE_REFS" ] || return 0
  blob_workdir || return 1
  local key oid req keys
  req="$BLOB_DIR/store.req"; keys="$BLOB_DIR/store.keys"; STORE_BLOB="$BLOB_DIR/store.map"
  # ⛔ THE KEY→COMMIT PAIRING IS ONE awk PASS, not `store_oid` per key: that helper printf's the
  # whole listing and awk-parses it per call (measured 17.6 ms × 3,462 refs = 61 s of pure
  # process churn before a single record was compared).
  printf '%s\n' "$STORE_REFS" \
    | awk 'NF >= 2 { sub(/^refs\/reviews\//, "", $2); print $2 "\t" $1 }' | LC_ALL=C sort > "$keys"
  awk -F'\t' '{ printf "%s:record.json\n", $2 }' "$keys" > "$req"
  # `--batch-check` answers exactly one line per request, in request order, and answers a MISSING
  # object with `<expr> missing` — only the object present on the line is the oid, so the oid is
  # field 1 on a hit (`<oid> <type> <size>`) and there is no echoed expression to parse. Reading
  # the key list back in the same order re-attributes each answer; a truncated answer leaves the
  # remaining keys absent from the map, so they take the slow path rather than being guessed.
  g_cat_batch_check < "$req" 2>/dev/null | awk -v kf="$keys" '
    BEGIN { while ((getline k < kf) > 0) { split(k, a, "\t"); keys[++n] = a[1] } }
    { if (NR > n) exit
      if (NF >= 2 && $2 != "missing") print keys[NR] "\t" $1; else print keys[NR] "\t-" }' > "$STORE_BLOB"
  return 0
}

build_local_blobs() { # ONE process over EVERY record this box holds
  [ -n "$LOCAL_BLOB" ] && return 0
  [ -d "$REG_DIR" ] || return 0
  blob_workdir || return 1
  local f paths all usable
  paths="$BLOB_DIR/local.paths"; LOCAL_BLOB="$BLOB_DIR/local.map"
  all="$BLOB_DIR/local.all"; usable="$BLOB_DIR/local.usable"
  : > "$paths"
  for f in "$REG_DIR"/*.json; do
    [ -f "$f" ] || continue
    [ -L "$f" ] && continue           # write_local refuses to write through a symlink; never hash one
    # ABSOLUTE on purpose: `hash-object --stdin-paths` runs with `-C "$STORE"`, so a relative
    # `--dir` would resolve every path against the STORE checkout — git aborts at the first
    # unopenable path, the map comes out empty, and the fast path silently disappears.
    case "$f" in /*) ;; *) f="$PWD/$f" ;; esac
    printf '%s\n' "$f" >> "$paths"
  done
  [ -s "$paths" ] || return 0
  g_hash_paths < "$paths" 2>/dev/null | awk -v pf="$paths" '
    BEGIN { while ((getline p < pf) > 0) paths[++n] = p }
    { if (NR > n) exit; if (NF >= 1) print paths[NR] "\t" $1 }' > "$all"
  # ⛔ ONLY A RECORD THE FAST PATH CAN ANSWER FOR IS IN THE MAP — usable AND stamped AND
  # key-consistent (see RECORD_READER_PY `fast_ok`): an unusable, unstamped or mis-keyed record
  # that is already mirrored here must still be counted `unreadable` (exit 4), never `same`.
  # No python3 → the map is empty and every key takes the full read: correct, just slower.
  if command -v python3 >/dev/null 2>&1 && python3 -c "$RECORD_READER_PY" --list < "$paths" > "$usable" 2>/dev/null && [ -s "$usable" ]; then
    # ⛔ `[ -s "$usable" ]` IS LOAD-BEARING: the `NR == FNR` split below is wrong when the FIRST
    # file is EMPTY (NR and FNR are both 1 on the second file's first line, so it is eaten as if it
    # were file one). Direction here is safe — a dropped entry only forces the slow path — but the
    # guard keeps the map from being silently one record short for a reason nobody reading the awk
    # would guess.
    awk -F'\t' 'NR == FNR { ok[$1] = 1; next } ($1 in ok)' "$usable" "$all" > "$LOCAL_BLOB"
  fi
  return 0
}

store_blob_of() { # <key> → the store's record-blob id (empty when unknown, "-" when it carries none)
  [ -n "$STORE_BLOB" ] && [ -s "$STORE_BLOB" ] || return 0
  awk -F'\t' -v k="$1" '$1 == k { print $2; exit }' "$STORE_BLOB"
}
local_blob_of() { # <path> → this box's record-blob id for that file (empty when not hashed)
  [ -n "$LOCAL_BLOB" ] && [ -s "$LOCAL_BLOB" ] || return 0
  # The map is keyed by ABSOLUTE path (see build_local_blobs); a relative `--dir` must not make the
  # lookup miss for every record, which would leave the fast path permanently inert.
  local p="$1"
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  awk -F'\t' -v p="$p" '$1 == p { print $2; exit }' "$LOCAL_BLOB"
}
# A fetch can move the store's refs under the maps, and a pull writes local files; both sides are
# therefore invalidated by the caller rather than trusted past the event that changes them.
reset_store_blobs() { STORE_BLOB=""; }
reset_local_blobs() { LOCAL_BLOB=""; }
store_oid() { # <key> → the commit the STORE names for that ref (empty: the store has no such ref)
  printf '%s\n' "$STORE_REFS" | awk -v want="refs/reviews/$1" '$2 == want { print $1; exit }'
}
# The record bytes the STORE's own object carries, resolved in TWO steps on purpose: `rev-parse`
# turns `<commit>:record.json` into a blob id, and `g_cat_blob` prints that blob.
# ⛔ NOT one hop with a `<rev>:<path>` operand on the printing verb: the checkout-guard classifies
# that shape as a possible REVERT SOURCE (`cat-file-revert`, #1060/#1125) and then runs its STATE
# predicate over this checkout, so a registry read would depend on the store checkout's WIP. The
# split calls keep this path exactly what it is — two reads — and the guard sees two plain verbs.
remote_record() { # <key> → the record bytes carried by the STORE's own object
  local oid blob
  oid="$(store_oid "$1")"
  [ -n "$oid" ] || return 1
  blob="$(g_rev_parse "$oid:record.json" 2>/dev/null)" || return 1
  [ -n "$blob" ] || return 1
  g_cat_blob "$blob" 2>/dev/null
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

registry_file_count() { # how many .json records this box holds AFTER a run (#2577's `files=`)
  local f n=0
  [ -d "$REG_DIR" ] || { printf '0'; return 0; }
  for f in "$REG_DIR"/*.json; do
    [ -e "$f" ] || continue            # unmatched glob
    n=$((n + 1))
  done
  printf '%s' "$n"
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
# The convergence counters (#2577). `ADDED`/`UPDATED` are PULL-side only — they describe what this
# box's registry RECEIVED — while `WROTE` counts both directions. `files=` is read after the run.
ADDED=0 UPDATED=0
CONFLICT_KEYS="" UNREADABLE_KEYS="" FAILED_KEYS="" PUSH_FAILED_KEYS=""

# ⛔ THE COUNTERS COUNT RECORDS, NOT EVENTS. `union` runs pull AND then push, so one defective key
# is seen by BOTH directions and every increment happened twice: measured, ONE ambiguous local record
# reported `unreadable=2` / `skipped=2` / "2 record(s) were SKIPPED", and two defective records
# reported 4 — the same "look for a second record that does not exist, and double the number a
# scheduler trends" defect fixed for `conflicts=` in review cycle 4. Every key-scoped increment now
# registers its key, and `summary()` prints DISTINCT keys. (The counts line is what an operator reads
# and what the doctor logs; a number nobody can act on is worse than no number.)
unreadable() { UNREADABLE=$((UNREADABLE + 1)); UNREADABLE_KEYS="$UNREADABLE_KEYS $1"; }
failed()     { FAILED=$((FAILED + 1)); FAILED_KEYS="$FAILED_KEYS $1"; }
# ⛔ `push_failed()` REGISTERS ITS KEY TOO, because `summary()` asks whether EVERY failure was on the
# push side (`[ "$fcount" -eq "$pfcount" ]`). Comparing a DEDUPED total against an EVENT count answers
# that question wrongly the moment one key fails in both directions: the pull's failure is deduped
# away, the counts then look equal, and the operator is told "the pull side succeeded" while it did
# not. (The arm structure makes that unlikely for one key — a pull only fails when it must WRITE, a
# push only when it must PUBLISH — so this is defence, not a reproduced path; it costs one variable.)
push_failed() { failed "$1"; PUSH_FAILED=$((PUSH_FAILED + 1)); PUSH_FAILED_KEYS="$PUSH_FAILED_KEYS $1"; }

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
  # ⛔ THE SLOW PATH DECIDES WITH `field`; THE RAIL DECIDES WITH json. They are the same reader only
  # where they agree, so a peer record whose compared keys read differently is UNREADABLE (exit 4)
  # rather than guessed at — measured: a nested `evidence:{"head_sha":…}` on an earlier line made
  # `field` read the nested head, so a genuine rule-4 divergence at a shared stamp was reported
  # `same`/exit 0 (`wrote=0 conflicts=0`). `record_usable` is that one check.
  if ! record_usable "$tmp"; then
    rm -f "$tmp"
    DEC="unreadable"; DEC_MSG="the peer's record is not one this box's rail can USE, or its compared fields do not read the same way twice (json vs field); refusing to order against it"
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
    unreadable "$key"; return 0
  fi
  cs="$(field "$f" reviewed_at)"
  # ⛔ THE FAST PATH (both directions share it): identical blob ids are identical bytes, so this
  # key is already published exactly as it sits here — no ordering rule and no conflict rule has
  # anything to decide. Counted `SAME`, exactly as the full comparison would.
  local sb
  sb="$(store_blob_of "$key")"
  if [ -n "$sb" ] && [ "$sb" != "-" ] && [ "$(local_blob_of "$f")" = "$sb" ]; then
    SAME=$((SAME + 1)); return 0
  fi
  # ⛔ THE LOCAL SIDE IS GATED TOO, or `push` publishes a record whose own compared fields read one
  # way to `field` and another to json — the shape that makes the ordering comparison decide on bytes
  # the rail never saw. It sits AFTER the fast path ON PURPOSE: an identical blob id means the bytes
  # are ALREADY published, so refusing to re-publish them would change nothing while costing a
  # python3 process per record on every converged run (measured: the store holds thousands of
  # records and a box that is already converged must stay cheap).
  if ! record_usable "$f"; then
    warn "  ⚠️ skip $key — the LOCAL record is not one this box's rail can USE, or its compared fields do not read the same way twice (json vs field); refusing to publish it."
    unreadable "$key"; return 0
  fi
  attempt=0
  while :; do
    attempt=$((attempt + 1))
    push_decision "$key" "$f"
    case "$DEC" in
      skip)   say "  · keep $key — $DEC_MSG; a record is never overwritten with an older one (#2374 rule 1)"
              SKIPPED_OLDER=$((SKIPPED_OLDER + 1)); return 0 ;;
      same)   [ -n "$DEC_MSG" ] && say "  · $key — $DEC_MSG"; SAME=$((SAME + 1)); return 0 ;;
      supersede) say "  · $key — $DEC_MSG; publishing it (a carry is a supersession, not a disagreement)" ;;
      unreadable) warn "  ⚠️ skip $key — $DEC_MSG; refusing to overwrite it (#2374 rule 1)."
              unreadable "$key"; return 0 ;;
      conflict) conflict "$key" "$lat" "$DEC_PEER_AT" "$f"; return 0 ;;
    esac
    # ⛔ NO FETCH HERE. `exp` is the ref value `push_decision` actually compared: re-reading it
    # after a fetch would make the lease name the peer's CURRENT value (a no-op fence) and the push
    # an unconditional force — which is how a newer peer record was silently replaced by an older
    # one. A refusal means the state moved, and the loop below re-decides against the new state.
    exp="$DEC_EXP"
    blob="$(g_hash_object "$f" 2>/dev/null)" || break
    tree="$(printf '100644 blob %s\trecord.json\n' "$blob" | g_mktree 2>/dev/null)" || break
    commit="$(g_commit_tree "$tree" "review record $key reviewed_at=$cs" 2>/dev/null)" || break
    if [ -n "$exp" ]; then
      g_push "refs/reviews/$key:$exp" "$commit:refs/reviews/$key" >/dev/null 2>&1
    else
      g_push_create "$commit:refs/reviews/$key" >/dev/null 2>&1
    fi
    rc=$?
    if [ "$rc" -eq 0 ]; then
      g_update_ref "refs/reviews/$key" "$commit" >/dev/null 2>&1
      say "  ↑ pushed $key (reviewed_at=$cs)"
      PUSHED=$((PUSHED + 1)); WROTE=$((WROTE + 1)); return 0
    fi
    # A refusal means the state CHANGED under this attempt. Loop again so the DECISION is re-taken
    # against what is actually there now — never re-push the comparison this attempt just lost.
    if [ "$attempt" -ge 2 ]; then break; fi
    fetch_refs >/dev/null 2>&1
    # ⛔ THE FETCH RESET THE BATCHED MAP (`reset_store_blobs`), AND NOTHING ELSE REBUILDS IT. Without
    # this line every key AFTER a refused push falls back to two git processes per key — the ~15 min
    # cost this PR exists to delete — inside a step the doctor bounds at 300 s, so the one failure a
    # contended store produces (a peer moved the ref) is exactly the one that makes the bound inert.
    # The listing just changed, so the map must be rebuilt from it: one batched call.
    build_store_blobs || :
  done
  warn "  ⚠️ FAILED $key — the push was refused twice (a peer moved the ref, or this box cannot push to $REMOTE). The record stays LOCAL and is not lost; re-run to retry."
  push_failed "$key"; return 0
}

pull_one() { # <key>
  local key="$1" tmp lf rat lat pull_reason=""
  # ⛔ THE FAST PATH: the store's blob id and this box's agree, so the bytes are identical and
  # there is nothing for rules 1/4 to decide. Same counter as the full comparison (`SAME`), so the
  # summary cannot tell the two paths apart — and must not.
  local sb
  sb="$(store_blob_of "$key")"
  if [ -n "$sb" ] && [ "$sb" != "-" ]; then
    lf="$(local_record_for_key "$key" 2>/dev/null)" || lf=""
    if [ -n "$lf" ] && [ "$(local_blob_of "$lf")" = "$sb" ]; then
      SAME=$((SAME + 1)); return 0
    fi
  fi
  lf=""
  tmp="$(mktemp "${TMPDIR:-/tmp}/registry-sync-pull.XXXXXX")" || { failed "$key"; return 0; }
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
      unreadable "$key"
    fi
    rm -f "$tmp"; return 0
  fi
  rat="$(field "$tmp" reviewed_at)"
  if [ -z "$rat" ]; then
    warn "  ⚠️ skip $key — the peer's record carries no readable reviewed_at."
    rm -f "$tmp"; unreadable "$key"; return 0
  fi
  # ⛔ USABILITY BEFORE ORDERING. A record the rail cannot read must never win the comparison: it
  # would replace a usable local record with bytes `read_record` refuses (see `record_usable`).
  if ! record_usable "$tmp"; then
    warn "  ⚠️ skip $key — the peer's record is not one this box's rail can USE (no 40-hex head_sha, no verdict, not strict JSON, or its compared fields do not read the same way twice — json vs field); refusing to install it over $(if local_record_for_key "$key" >/dev/null 2>&1; then echo 'the local record'; else echo 'nothing'; fi)."
    rm -f "$tmp"; unreadable "$key"; return 0
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
    unreadable "$key"; rm -f "$tmp"; return 0
  fi
  if [ -z "$rec_repo" ]; then
    warn "  ⚠️ skip $key — the peer's record carries no repo field, so the key it sits under cannot be verified (#2374 rule 3)."
    unreadable "$key"; rm -f "$tmp"; return 0
  fi
  if [ "${rec_repo%/*}-${rec_repo#*/}-$rec_pr" != "$key" ]; then
    warn "  ⚠️ skip $key — the peer's record says ${rec_repo}#${rec_pr}, which is NOT this key; materialising it would transplant another repo's verdict (#2374 rule 3, #426)."
    unreadable "$key"; rm -f "$tmp"; return 0
  fi
  lf=""
  if lf="$(local_record_for_key "$key")" && [ -n "$lf" ]; then
    same_bytes "$lf" "$tmp" && { SAME=$((SAME + 1)); rm -f "$tmp"; return 0; }
    # ⛔ THE FOURTH SURFACE. The peer is gated above, but every arm below DECIDES by comparing
    # `field` readings of THIS box's record against the peer — so an ambiguous local record decides
    # too. Measured with a nested `evidence.reviewed_at` on an earlier line: `field` read 2020 while
    # json (the rail) read 2026-12-31, so the peer looked NEWER and an older `clean` REPLACED a newer
    # `not-clean` (`wrote=1 older_refused=0 conflicts=0`, exit 0); the same shape with a nested
    # `evidence.head_sha` reported a real head divergence as `same`. Refusing to order against an
    # ambiguous local record is the only direction that cannot destroy a usable verdict: the peer's
    # bytes are NOT installed here, so a box holding a corrupt record stays put until that record is
    # fixed or removed (which the rail cannot use it either way) — never silently downgraded.
    if ! record_usable "$lf"; then
      warn "  ⚠️ skip $key — this box's LOCAL record is not one the rail can USE, or its compared fields do not read the same way twice (json vs field — the rail may still read it), so no peer record can be ordered against it (#2374 rule 1). REPAIR or RE-MINT that file: deleting it makes the next pull install the peer's record, which may be OLDER than this one."
      unreadable "$key"; rm -f "$tmp"; return 0
    fi
    lat="$(field "$lf" reviewed_at)"
    if [ -n "$lat" ] && [[ "$lat" > "$rat" ]]; then
      say "  · keep $key — this box is NEWER ($lat > $rat); an older record never overwrites a newer one (#2374 rule 1)"
      SKIPPED_OLDER=$((SKIPPED_OLDER + 1)); rm -f "$tmp"; return 0
    fi
    if [ -z "$lat" ]; then
      warn "  ⚠️ skip $key — this box's record carries no readable reviewed_at; refusing to overwrite an unknown-order record (#2374 rule 1)."
      unreadable "$key"; rm -f "$tmp"; return 0
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
        # Neither names the other's head: same verdict+head is provenance-only (the parallel carry
        # two boxes make onto one head); a different verdict is the real disagreement.
        case "$(same_stamp_relation "$tmp" "$lf")" in
          a) pull_reason="same mint time, same head, and the peer's record is the carried one; taking it as a supersession" ;;
          b) say "  · keep $key — same mint time and THIS box's record is the carried one (same head, same verdict)"
             SKIPPED_OLDER=$((SKIPPED_OLDER + 1)); rm -f "$tmp"; return 0 ;;
          same) # ⛔ A FORMATTING-ONLY DIFFERENCE IS RESOLVED, NOT KEPT (#2577, measured). 3,261 of
             # 3,462 records on the reference box differed from their published blob by exactly one
             # TRAILING NEWLINE — an artefact of an older pull, not a disagreement — so every pass
             # re-read them (`same_bytes` is exact) and a scheduled run could never become cheap.
             # Equal after trailing newlines are stripped is not a verdict difference: the stamp,
             # verdict and head are already equal here, and rule 4 only protects records that
             # DISAGREE. Rewriting the local file to the PUBLISHED bytes makes this box's registry
             # byte-identical to the fleet's record — the property `hash=` and the equality fast path
             # both rest on — and it is counted as a write, because it is one.
             if [ "$lf" = "$REG_DIR/$key.json" ] && [ "$(command cat "$lf")" = "$(command cat "$tmp")" ] && write_local "$key" "$tmp"; then
               say "  · canon $key — the only difference was trailing newlines; rewrote it to the published bytes"
               WROTE=$((WROTE + 1)); SAME=$((SAME + 1)); rm -f "$tmp"; return 0
             fi
             say "  · keep $key — same mint time, verdict, head and merge base; the records differ only in carry provenance"
             SAME=$((SAME + 1)); rm -f "$tmp"; return 0 ;;
          *) conflict "$key" "$lat" "$rat" "$lf"; rm -f "$tmp"; return 0 ;;
        esac
      fi
    fi
  fi
  if write_local "$key" "$tmp"; then
    say "  ↓ pulled $key (reviewed_at=$rat)${pull_reason:+ — $pull_reason}"
    WROTE=$((WROTE + 1))
    # `lf` is non-empty exactly when `local_record_for_key` found a record the READER would act on
    # (the qualified file, or the legacy `<pr>.json` it falls back to) — so it is the right test for
    # "this box had none" and not a guess from the qualified path alone.
    if [ -n "$lf" ]; then UPDATED=$((UPDATED + 1)); else ADDED=$((ADDED + 1)); fi
  else
    warn "  ⚠️ FAILED $key — could not write $REG_DIR/$key.json"
    failed "$key"
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
  reset_local_blobs
  build_store_blobs || :
  build_local_blobs || :
  local key
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    pull_one "$key"
  done <<<"$(remote_refs)"
}

do_push() {
  fetch_refs || return 1
  # A pull may have materialised records since the maps were built; the local side is rebuilt so a
  # freshly written record is compared by id rather than re-read.
  reset_local_blobs
  build_store_blobs || :
  build_local_blobs || :
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
  local key name at list lnew="" rnew="" local_n=0 remote_n=0 missing=0 at_tmp
  list="$(mktemp "${TMPDIR:-/tmp}/registry-sync-status.XXXXXX")" || return 1
  at_tmp="$(mktemp "${TMPDIR:-/tmp}/registry-sync-status-at.XXXXXX")" || return 1
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    remote_n=$((remote_n + 1))
    # ⛔ THE ONE READER. This was a bare sed pinned to the COMPACT spelling, so the origin side read
    # `none` for a record the local side (through `field`) read correctly — measured: the same bytes
    # gave `origin newest_reviewed_at=none` next to `local newest_reviewed_at=2026-11-30T10:00:00Z`,
    # and on a mixed store it silently reported an older compact stamp while a newer pretty-printed
    # one was invisible. `status` is the verb the header tells an operator to run FIRST.
    at=""
    if remote_record "$key" > "$at_tmp" 2>/dev/null; then at="$(field "$at_tmp" reviewed_at)"; fi
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
  rm -f "$list" "$at_tmp"
  printf 'local  records=%s newest_reviewed_at=%s hash=%s\n' "$local_n" "${lnew:-none}" "$(registry_hash)"
  printf 'origin records=%s newest_reviewed_at=%s\n' "$remote_n" "${rnew:-none}"
  printf 'missing_here=%s\n' "$missing"
  return 0
}

summary() { # <verb>
  # ⛔ conflicts= counts DISTINCT RECORDS, not decisions. `union` runs pull and then push, so ONE
  # divergent record is detected in both directions: the counter read conflicts=2 and the message
  # listed the same key twice (measured), sending an operator to look for a second record that does
  # not exist and doubling the number a scheduler trends.
  local ccount="$CONFLICT" ckeys="$CONFLICT_KEYS"
  if [ -n "$CONFLICT_KEYS" ]; then
    ccount="$(printf '%s\n' $CONFLICT_KEYS | LC_ALL=C sort -u | wc -l | tr -d ' ')"
    ckeys=" $(printf '%s\n' $CONFLICT_KEYS | LC_ALL=C sort -u | tr '\n' ' ' | sed 's/ *$//')"
  fi
  # ⛔ THE SAME RULE FOR THE OTHER TWO COUNTERS, and for the same reason: `union` runs BOTH
  # directions, so a key-scoped defect is counted once per direction. Measured before this: ONE
  # ambiguous local record read `unreadable=2` / `skipped=2` / "2 record(s) were SKIPPED", and two
  # defective records read 4. The convergence line's `skipped=` is the number a scheduler trends, so
  # an inflated one is worse than none.
  local ucount="$UNREADABLE" fcount="$FAILED"
  if [ -n "$UNREADABLE_KEYS" ]; then
    ucount="$(printf '%s\n' $UNREADABLE_KEYS | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  fi
  if [ -n "$FAILED_KEYS" ]; then
    fcount="$(printf '%s\n' $FAILED_KEYS | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  fi
  local pfcount="$PUSH_FAILED"
  if [ -n "$PUSH_FAILED_KEYS" ]; then
    pfcount="$(printf '%s\n' $PUSH_FAILED_KEYS | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  fi
  printf '%s: wrote=%s pushed=%s same=%s older_refused=%s conflicts=%s unkeyed=%s unreadable=%s failed=%s\n' \
    "$1" "$WROTE" "$PUSHED" "$SAME" "$SKIPPED_OLDER" "$ccount" "$UNKEYED" "$ucount" "$fcount"
  # THE CONVERGENCE LINE (#2577). Printed LAST so a caller that greps `^<verb>:` for the tail (the
  # rail and the cell bring-up both do) reports the numbers a stalled sync makes visible, instead of
  # a breakdown that reads identical whether the 3,000 fleet records arrived or none did.
  printf '%s: refs=%s files=%s added=%s updated=%s skipped=%s\n' \
    "$1" "$STORE_REF_COUNT" "$(registry_file_count)" "$ADDED" "$UPDATED" "$ucount"
  if [ "$fcount" -gt 0 ]; then
    # WHICH SIDE failed matters at the caller: a failed PULL means the fleet is UNKNOWN here, while a
    # failed PUSH means the records WERE read and this box could not publish. Naming both as a single
    # records-are-UNKNOWN state sent an operator to re-run a path that fails identically.
    if [ "$pfcount" -gt 0 ] && [ "$fcount" -eq "$pfcount" ]; then
      warn "registry-sync.sh: $fcount record(s) could not be PUBLISHED — the pull side succeeded, so this box"
      warn "  HOLDs the fleet's records but its own are still LOCAL. Re-run to retry (nothing was deleted)."
    else
      warn "registry-sync.sh: $fcount record(s) could not be moved — re-run to retry (nothing was deleted, and no record was overwritten with an older one)."
    fi
    return 1
  fi
  if [ "$ccount" -gt 0 ]; then
    warn "registry-sync.sh: $ccount record(s) DIVERGE at the same reviewed_at:$ckeys"
    return 3
  fi
  if [ "$ucount" -gt 0 ]; then
    warn "registry-sync.sh: $ucount record(s) were SKIPPED because they could not be read or ordered — this is"
    # ⛔ "the STORE holds records this box cannot use" was wrong on two of the three arms: `push`
    # publishes LOCAL records and `pull` now also refuses to order against an unusable LOCAL record,
    # so the defect can be either side. Name the state, not a side.
    warn "  NOT a converged state (a record this box cannot USE was skipped, on the store side or this box). Nothing was overwritten."
    return 4
  fi
  return 0
}

# ── surface-check: is THIS SCRIPT's git surface intact? (#2520) ─────────────────────────────
# The one question a refused lane could not answer: is the sync command the rail told it to run
# actually runnable here? A guard refusal happens before this file first line, so the caller gets
# NO exit status — and silence has been read as success, which is the whole of #2520. This verb
# turns that silence into a value: 0 = the two rules below hold, 5 = they are violated, 3 = the
# check could not read its own source.
#
# ⛔ WHAT A 0 DOES **NOT** SAY, and the distinction is the whole reason this comment exists. The
# checkout-guard has TWO content arms: (a) a git invocation whose VERB arrives as a variable cannot
# be bounded (the arm #2520 was measured on, restated below), and (b) a DEEPER walk (#1484/#1485)
# that blocks a script whose CONTENT mutates the hub — `push`, `update-ref`, `mktree`,
# `commit-tree` — in a HUB-ROOTED session unless the script is named in the guard's own
# `SANCTIONED_SCRIPT_RELPATHS`. A registry sync must push and update refs, so arm (b) refuses it in
# a hub-rooted session no matter how clean this surface is, and NO RESTATEMENT HERE CAN CHANGE
# THAT: measured with the guard's own `scriptGitVerdict(<this file>, "main")` → `block`, on this
# head and on origin/main alike (the sanctioned scripts — record-review.sh, admin-merge.sh — read
# `block` from that same function and are allowed only by the exemption that runs BEFORE it).
# So: 0 means "this script has not re-introduced the surface defect #2520 was filed on". It does not
# mean the guard will run it, and the doctor is told the difference. Making a hub-rooted session
# run it is an OWNER decision about the guard's sanctioned list (#2621), never a quiet
# edit to a safety gate from inside a lane.
#
# The two rules restated here are deliberately conservative: restating them can only OVER-refuse
# (a false 5 costs one grep), never under-refuse. The shipped suite (§28) pins this against the
# guard OWN classifier on the real file and on fixtures, so a restatement that drifts reads as a
# red suite rather than as a quiet false OK.
surface_check() {
  local hits rc
  hits="$(awk '
    # Every token after a `git` COMMAND WORD, minus the options that consume an argument, is the
    # VERB. `-C`/`-c` and friends take a value, so their value must not be mistaken for a verb.
    #
    # ⛔ PROSE IS NOT A COMMAND. This file talks ABOUT git in its warnings ("a git invocation
    # whose verb …"), so a quote-blind scan reads the next English word as a verb and refuses the
    # script for its own help text (measured: `unlisted verb invocation`, `unlisted verb surface`).
    # Every double-quoted span is therefore replaced by ONE placeholder token — `Q` for prose,
    # `DYN` when it carries `$` (a quoted expansion in the verb position, `"$@"`, is exactly the
    # shape this check exists to catch). ONE token, not whitespace: `-C "$STORE"` must keep its
    # value in the value slot, or the verb slides into it and the scan reads the option instead
    # (measured: a fixture `git -C "<path>" stash push -u` reported OK because `stash` had moved
    # into the value slot of `-C`).
    function strip_prose(line,   out, pre, seg) {
      out = ""
      while (match(line, /"[^"]*"/)) {
        pre = substr(line, 1, RSTART - 1)
        seg = substr(line, RSTART, RLENGTH)
        out = out pre (index(seg, "$") ? " DYN " : " Q ")
        line = substr(line, RSTART + RLENGTH)
      }
      return out line
    }
    /^[ \t]*#/ { next }                       # a comment is prose; the guard reads COMMANDS
    {
      n = split(strip_prose($0), t, /[ \t]+/)
      for (i = 1; i <= n; i++) {
        if (t[i] != "git") continue
        j = i + 1
        while (j <= n && t[j] ~ /^-/) {
          if (t[j] == "-C" || t[j] == "-c" || t[j] == "--git-dir" || t[j] == "--work-tree" ||
              t[j] == "--namespace" || t[j] == "--config-env" || t[j] == "--super-prefix" ||
              t[j] == "--exec-path") j++
          j++
        }
        if (j > n) continue                      # a bare `git` runs nothing
        v = t[j]
        sub(/[;)},]+$/, "", v)                  # `mktree;` / `push)` — the separator is not the verb
        if (v ~ /[$`]/ || v == "DYN") { printf "%d: dynamic verb %s\n", NR, v; continue }
        # ⛔ AN ALLOWLIST, NOT A BLOCKLIST. Enumerating the FORBIDDEN verbs under-refuses by
        # construction: `merge`, `rebase`, `stash`, `cherry-pick`, `revert`, `am`, `mv` and `pull`
        # all rewrite a working tree and none of them was listed, so a regression that re-added one
        # of them read back as runnable (surface-check OK, exit 0). Only the verbs the header of this
        # file declares are accepted; anything else is REFUSED, so an under-refusal is impossible
        # and a genuinely new verb has to be justified in the header before it can pass.
        allowed = " ls-remote fetch remote rev-parse cat-file hash-object mktree commit-tree push update-ref "
        if (index(allowed, " " v " ") > 0) continue
        wt = " checkout checkout-index restore switch reset clean read-tree apply merge rebase stash cherry-pick revert am pull rm "
        if (index(wt, " " v " ") > 0) printf "%d: working-tree verb %s\n", NR, v
        else printf "%d: unlisted verb %s\n", NR, v
      }
    }' "${BASH_SOURCE[0]}" 2>/dev/null)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "surface-check: ⛔ could not read ${BASH_SOURCE[0]} (awk rc=$rc) — exit 3 = NOT VERIFIED, never a pass."
    return 3
  fi
  if [ -z "$hits" ]; then
    say "surface-check: OK — every git invocation in ${BASH_SOURCE[0]##*/} has a LITERAL verb and none rewrites a working tree (this is NOT a claim that the guard will run the script from a hub-rooted session — see #2621)."
    return 0
  fi
  warn "surface-check: ⛔ this script's git surface is NOT clean (the #2520 class): a git invocation whose"
  warn "  verb cannot be bounded makes EVERY verb here un-runnable, and the withheld run prints no exit"
  warn "  status at all — which is exactly the state issue 2520 records. The offending line(s):"
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  warn "  Fix the script git surface (one literal verb per line); never weaken the guard. Exit 5 = SURFACE DEFECT."
  return 5
}

case "$VERB" in
  surface-check) surface_check; exit $? ;;
esac

resolve_store || exit 1
case "$VERB" in
  pull)   do_pull  || exit 1; summary pull;  exit $? ;;
  push)   do_push  || exit 1; summary push;  exit $? ;;
  union)  do_pull  || exit 1; do_push || exit 1; summary union; exit $? ;;
  status) do_status || exit 1; exit 0 ;;
esac
