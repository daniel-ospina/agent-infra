#!/usr/bin/env bash
# verify-landing-chain.sh — for a MERGED PR: was the code that LANDED the code that was REVIEWED,
# and did a GREEN run at that head gate the landing? (#4016 capstone conditions 3, 4, 5, 6)
#
# ⛔ THIS IS NOT A MERGE GATE AND IT MUST NEVER BECOME ONE. It decides nothing about whether a PR may
# land — that is `scripts/admin-merge.sh` (the rail), and this file is not wired into it. What it
# does is answer, AFTER the fact and from durable artifacts, the four questions #4016 is closed on,
# so the capstone is closable on EVIDENCE rather than on prose.
#
# WHY IT EXISTS (every clause is a measured shape, not a worry)
# ------------------------------------------------------------
# #4016 is the epic's definition of done and says outright that a capstone closed on "the mechanism
# exists" is the false-PASS class this repo already names. The links it demands per PR are:
#     issue → order record → lane → PR → REVIEW RECORD → fix commit → GREEN CHECK RUN → landing
# The 2026-11-12 measurement pass on #4016 found four of those links had NO instrument: they were
# hand-read once by an agent, and would have to be hand-read again after every child landed. Two of
# the hand-read shapes are also unverifiable in the direction that matters:
#
#   * a review record at head A, then a fix pushed to head B, then B merged with the record still
#     naming A — "reviewed code ≠ merged code", an attestation standing over content nobody reviewed.
#     NOTHING in the repo compared the REVIEWED CONTENT to the LANDED CONTENT.
#   * `check-pipeline-compliance.sh` check (c) asks only "is there a record marker at the CURRENT
#     head". A marker can sit at the current head while the run there was red, or while the run
#     finished AFTER the merge. NOTHING asked "was the verdict that gated the landing a green one".
#
# WHAT IT ASSERTS — six predicates, one line each, per PR
# ------------------------------------------------------
#   merged         the PR is MERGED and the merge commit's tree is readable. No merge ⇒ no landing.
#   review_record  a review record exists AND is ADMITTED (the recorder's own marker, read from the PR
#                  body or its comments — durable and therefore CROSS-BOX; a local
#                  ~/.pi/agent/reviews/<owner>-<repo>-<pr>.json is a fallback only). Admission is the
#                  required check's own rule, not a weaker one this file invented: a COMMENT marker must
#                  come from `author_association ∈ OWNER|MEMBER|COLLABORATOR` and carry a `sig=` that
#                  verifies wherever a gate key resolves (no key ⇒ the association is the admission, and
#                  the detail says so); a record FILE must carry a `sig=` that verifies under the same
#                  key. A body marker needs write access to the PR, and the gate's legacy unsigned
#                  tolerance for it is kept. Anything else is REPORTED as refused, never promoted.
#   review_bound   THE REVIEWED HEAD IS THE PR'S FINAL COMMIT — nothing was pushed to the PR after
#                  the review. This repo squash-merges (measured 2026-11-12: PR #3996's merge commit
#                  5de01a204 has ONE parent and head 1dc591316 is not on main), so `parents[1]` cannot
#                  name the reviewed head.
#
#                  ⛔ TREE EQUALITY IS **WRONG** HERE, AND IT WAS MEASURED WRONG, NOT GUESSED. The
#                  first cut of this file compared `tree(reviewed_head)` to `tree(merge_commit)` and
#                  reported FAIL on PR #3996 — a FALSE FAIL. A squash applies the PR's DIFF to the
#                  CURRENT main, so the resulting tree equals the head's tree ONLY when main has not
#                  moved since the branch point. On #3996 main had moved (merge parent1 7a1d389ec
#                  vs the branch's own base), the trees legitimately differ, and the reviewed head
#                  1dc591316 was in fact the PR's LAST commit — nothing unreviewed landed at all.
#                  A predicate that fails a correct landing teaches its reader to ignore it, so the
#                  binding is the base-independent one: the reviewed head IS the final commit of
#                  `pulls/<pr>/commits`, and any commit after it is PRINTED BY SHA as the unreviewed
#                  push. The landed tree is still reported, as a datum, never as the verdict.
#   fix_round      a `not-clean` verdict must be followed by a record at a DIFFERENT head (capstone
#                  condition 4). A not-clean never superseded is a FAIL. No not-clean is N/A — never
#                  a silent PASS.
#   green_gated    at the moment of the merge the newest attempt of EVERY check group was GREEN and
#                  completed (condition 5: the green gated the landing, not an override past a red).
#   rail_landed    the rail landed it on its own, with no `admin_merge_override` recorded ON THAT
#                  LANDING (condition 6). Artifact-only, and decided on POSITIVE evidence: the rail's
#                  own `merged PR #<n>` line. A scratch file that exists is not a landing — a refusal
#                  and an ALREADY-MERGED no-op leave one too (fresh-context review, round 6).
#
# THE SURFACE IS READ AS-OF-`mergedAt`, ON PURPOSE
# ----------------------------------------------
# "Newest attempt per check" (AGENTS.md, "Reading verification state") answers "is the tree healthy
# NOW". The capstone asks what the landing actually SAW, so the newest attempt is taken among the
# attempts whose `completed_at` is at or before `mergedAt`. A green that completed AFTER the merge did
# not gate that merge; counting it is the flattering direction, and it would also let a re-run
# launder a red.
#
# GROUPING IS (app, workflow, job name), NEVER THE NAME ALONE
# -----------------------------------------------------------
# Two workflows can publish the same job name (measured: two `packaging-smoke` runs, one `cancelled`
# and one `success`). Grouping on the name merges them so the newest of one masks the other, so the
# workflow is resolved from the check-run's `details_url` run id against the commit's own runs list —
# ONE extra read per head, not one per run id. A check-run whose Actions workflow cannot be resolved
# groups under its app slug alone; it is never dropped, because a check that forms no group can never
# make a verdict red.
# ⛔ THE WORKFLOW COMPONENT IS THE WORKFLOW'S `path`, NOT ITS DISPLAY `name` (fresh-context review,
# round 7, P3). `name:` is free text a repo can repeat, so two DISTINCT workflows sharing a display
# name collapsed into one group and the newer of one could still mask the other — case 8 was narrowed,
# not closed. `.path` (`.github/workflows/<file>.yml`) is unique per repo and is in the same payload.
# The display name stays the FALLBACK, so a snapshot or an older runs read still groups sensibly.
#
# VERDICTS — `PASS | FAIL | INCONCLUSIVE | N/A`
# --------------------------------------------
# INCONCLUSIVE is a read that did not happen (gh refused, no snapshot file, no artifacts on this
# box). It renders differently from PASS, it makes the exit code non-zero, and it is NEVER collapsed
# into PASS or FAIL — a blind read that reads green is how a blind fleet looks healthy (the rule
# `tools/fleet/outcome_canary.py` states).
#
# USAGE
#   verify-landing-chain.sh <PR> [<PR> ...] [--repo owner/repo] [--json]
#   verify-landing-chain.sh --issue <N> [--repo owner/repo]    # the merged PR that closed an issue
#   verify-landing-chain.sh --from-snapshot DIR                # read a snapshot, never touch gh
#   verify-landing-chain.sh --write-snapshot DIR <PR> ...      # fetch once, keep it as evidence
#
#   --from-snapshot DIR   every read comes from DIR (the suite's offline mode; also how a cell
#                         verifies a PR it cannot reach gh for — the snapshot IS the evidence).
#   --write-snapshot DIR  fetch into DIR and KEEP it (the artifact a capstone record attaches).
#   --json                one JSON object on stdout, for a report or a frozen evidence file.
#
# ENV: VERIFY_AWK   the awk that renders `--json` (default `awk`). Set it to `awk --posix` to run the
#                   emitter under the portable-subset rules the suite asserts; any other read in this
#                   file is unaffected.
#
# EXIT: 0 every check PASS or N/A · 1 at least one FAIL · 2 no FAIL but at least one INCONCLUSIVE ·
#       3 usage error. (The same ladder as outcome_canary.py, deliberately.)
#
# BASH 3.2: this file must parse and run under the macOS system bash (`bash32-parse` in CI). No
# associative arrays, no `mapfile`, no `${x,,}`. Anything needing a map is done in awk.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH="${AGENT_GH_REAL:-gh}"
# ⛔ `${REPO:-}` AND NOT `REPO=""`: a bare assignment would DISCARD the box's own `REPO` pin, so the
# resolver below would never see the value the operator set and every run would refuse. (Measured:
# `REPO=owner/name ./verify-landing-chain.sh` refused until this line stopped clobbering it.)
REPO="${REPO:-}"
PRS=""
ISSUE=""
SNAPSHOT_IN=""
SNAPSHOT_OUT=""
JSON=0

usage() {
  awk 'NR == 1 { next } /^#/{ sub(/^# ?/, ""); print; next } { exit }' "$0" >&2
  exit 3
}

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)           [ $# -ge 2 ] || usage; REPO="$2"; shift 2 ;;
    --issue)          [ $# -ge 2 ] || usage; ISSUE="$2"; shift 2 ;;
    --from-snapshot)  [ $# -ge 2 ] || usage; SNAPSHOT_IN="${2%/}"; shift 2 ;;
    --write-snapshot) [ $# -ge 2 ] || usage; SNAPSHOT_OUT="${2%/}"; shift 2 ;;
    --json)           JSON=1; shift ;;
    --help|-h)        usage ;;
    -*)               printf 'verify-landing-chain: unknown option %s\n' "$1" >&2; usage ;;
    *)                PRS="$PRS $1"; shift ;;
  esac
done

# ── snapshot modes are MUTUALLY EXCLUSIVE, and saying so is part of the contract ─────────────────
# ⛔ `--write-snapshot DIR --from-snapshot DIR` USED TO BE A SILENT NO-OP (fresh-context review, round 8,
# P3): the read mode won, the write target was never created, and no word was said — so an operator who
# asked for an evidence directory got a verification with no artifact attached and nothing to notice it
# by. Two modes that cannot both be honoured are a USAGE error (exit 3), not a preference order.
if [ -n "$SNAPSHOT_IN" ] && [ -n "$SNAPSHOT_OUT" ]; then
  printf 'verify-landing-chain: --from-snapshot and --write-snapshot are mutually exclusive — a run either READS a frozen snapshot or WRITES one; pick one. (Nothing was verified.)\n' >&2
  usage
fi

# ── repo resolution ──────────────────────────────────────────────────────────────────────────────
# ⛔ NO PRIVATE PATH DEFAULT IS ASSIGNED TO `REPO` HERE. `check-single-source.sh`'s REPO path-default
# arm refuses exactly that shape, and it is right to: `REPO` is set ONCE per box (a launchd plist on
# a Mac, keys.env on a cell) and read through `repo-slug.sh`'s `resolve_repo`, which REFUSES a value
# by name. A per-script default points every other box at a path it does not have — and `$PWD` is `/`
# under launchd, which is a real directory that is not a repo. So the ONE resolver is the only default
# this file takes, and when it cannot prove a slug the script REFUSES and names the fix.
if [ -z "$REPO" ] && [ -f "${SNAPSHOT_IN:-/nonexistent}/repo.txt" ]; then
  REPO="$(tr -d '\r\n' < "$SNAPSHOT_IN/repo.txt")"
fi
# The ONE slug parser, sourced rather than re-implemented: a second URL parse is how the pool and the
# grading drift apart (#2040). It is used in BOTH directions below — to test a value, and to turn a
# box's path-form `REPO` pin into a slug.
#
# ⛔ BUT A MISSING MODULE MUST NOT REFUSE AN EXPLICIT `--repo` (fresh-context review, round 2 F1 —
# measured: a lone copy of this script in a directory without `repo-slug.sh` called the undefined
# `repo_slug_valid`, clobbered the caller's `--repo o/r` with the empty result, and exited 3 BEFORE
# any predicate ran. That also made this file's own mutation suite vacuous, because every mutant is
# exactly such a copy: each asserted on an empty report and "passed" by absence). So when the module
# is absent the shape rule below stands in — it is the same rule the module applies for the SLUG form,
# and it never derives a path. The module, when present, is still the only thing that parses a URL.
if [ -f "$HERE/repo-slug.sh" ]; then
  # shellcheck source=orchestrator-harness/repo-slug.sh
  . "$HERE/repo-slug.sh" >/dev/null 2>&1 || :
fi
slug_shaped() { # an owner/name with no path, scheme or extra segment — the module's slug rule
  case "${1:-}" in ''|*/*/*|/*|*:*) return 1 ;; */*) : ;; *) return 1 ;; esac
  case "${1%%/*}" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "${1#*/}"  in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}
slug_ok() { # the module's rule when it is loaded, the local shape rule otherwise
  if command -v repo_slug_valid >/dev/null 2>&1; then repo_slug_valid "$1" 2>/dev/null; else slug_shaped "$1"; fi
}
case "$REPO" in
  */*)
    # a box may pin REPO to a CHECKOUT (that form is supported and must not be mistaken for a slug);
    # anything that is not already a slug is derived through the same parser, never parsed here.
    if ! slug_ok "$REPO" && command -v derive_or >/dev/null 2>&1; then
      REPO="$(derive_or "$REPO" "" 2>/dev/null)" || REPO=""
    fi ;;
esac
if ! slug_ok "$REPO"; then
  printf 'verify-landing-chain: owner/repo is not resolved — the harness carries NO default for it.\n' >&2
  printf '  Pass --repo owner/repo, or point a snapshot at a repo.txt, or set REPO the one way this\n' >&2
  printf '  box has for it (the launchd plist on a Mac, keys.env on a cell; a checkout path is fine —\n' >&2
  printf '  it is derived through scripts/orchestrator-harness/repo-slug.sh).\n' >&2
  exit 3
fi
OWNER="${REPO%%/*}"; RNAME="${REPO#*/}"

# ── artifact locations (one definition each; --from-snapshot overrides the FETCH, not the names) ──
O="${O:-$HOME/orchestrator}"
RAIL_DIR="${RAIL_DIR:-$HOME/.pi/agent/state/rails}"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Time helpers — the `mergedAt` window is the ONE repo-scoped fact this file can use to attribute a
# PR-number-keyed artifact (F4). Two spellings, because `date -d` is GNU and `date -j -f` is BSD, and
# a silent empty answer from either must read as "unusable" rather than as "in window".
# ════════════════════════════════════════════════════════════════════════════════════════════════
CHAIN_MARKER_WINDOW="${CHAIN_MARKER_WINDOW:-21600}"   # 6h: generous for a slow chain, tight enough
                                                      # that another repo's merge of the same number
                                                      # (days or weeks away) can never fall inside it
# The awk that renders the `--json` evidence. It is a seam, not a knob: the JSON emitter must hold to
# the PORTABLE subset (no gawk-only replacement escapes), and the suite exercises exactly that by
# pointing this at `awk --posix` for one run. Left unset it is plain `awk`, like every other read here.
VERIFY_AWK="${VERIFY_AWK:-awk}"
iso_epoch() { # iso_epoch <2026-11-12T05:05:55Z> → seconds since epoch, or EMPTY
  local t="${1:-}"
  case "$t" in ""|-) return 1 ;; esac
  case "$t" in
    *Z) : ;;
    *) return 1 ;;
  esac
  # The BSD arm is `date -j -f`, which the detector's mechanism table has no row for (it knows `date -r`
  # as BSD's mechanism, and `-j` is two known mechanisms only when the second one is `-r`/`-d`), so this
  # PAIR never reaches the "two mechanisms ⇒ guarded" carve-out. Declared rather than baselined: the
  # suppression sits on the line it describes, so it cannot outlive the code it excuses (F1, PR #4043).
  date -u -d "$t" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$t" +%s 2>/dev/null || printf ''  # portability-ok: GNU `date -d` and BSD `date -j -f` in one `||` chain — portable as written; the detector has no `date -j` mechanism row, so the guarded-pair carve-out cannot see it (a baseline row would instead be deletable without touching this code)
}

file_mtime() { # file_mtime <path> → ISO-8601 UTC, or EMPTY (GNU stat, then BSD stat)
  local p="${1:-}" e=""
  e="$(stat -c %Y "$p" 2>/dev/null || stat -f %m "$p" 2>/dev/null)" || return 1
  case "$e" in ''|*[!0-9]*) return 1 ;; esac
  date -u -r "$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$e" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf ''
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Fetch — everything a predicate needs becomes a FILE, so gh is touched at most once per head and
# the analysis is a pure function of a directory. That is also what makes the suite hermetic: a
# fixture directory is the same shape as a fetched one.
# ════════════════════════════════════════════════════════════════════════════════════════════════

# pr.meta              <number> TAB <state> TAB <mergedAt|-> TAB <mergeCommit.oid|->
# body.txt             the PR body
# comments.txt         the PRODUCER frame: one record per comment, "<author_association>\x1f<body>\x1e"
#                      (check-pipeline-compliance.sh REVIEW_COMMENTS_JQ) — the author travels WITH the
#                      body, because a comment is the one record channel any account can write
# record.json          this box's record file, when one exists (fallback source)
# rail.out             the rail's output for this PR (every ATTEMPT of it, including refusals — so
#                      its presence says "the rail was asked", and only the rail's own
#                      `merged PR #<n>` line inside it says it LANDED this PR)
# chain.merged         the per-PR chain's `state/merged-<pr>.done` marker
# chain.verdict        lane-merge.sh's machine verdict for the PR
# merge.log            the per-PR chain's log
# commit-<sha>.tsv     <sha> TAB <tree> TAB <comma-separated parents>
# runs-<sha>.tsv       <run_id> TAB <workflow name> TAB <run_attempt> TAB <workflow path>
# checkruns-<sha>.tsv  <id> TAB <app> TAB <name> TAB <status> TAB <conclusion> TAB <completed_at> TAB <details_url>
fetch_one() { # fetch_one <dir> <pr>
  local dir="$1" pr="$2" sha rail rec legacy
  mkdir -p "$dir" || return 2
  printf '%s\n' "$REPO" > "$dir/repo.txt"
  store_read "$dir" pr.meta \
    "$GH" pr view "$pr" --repo "$REPO" --json number,state,mergedAt,mergeCommit \
      --jq '[.number, .state, (.mergedAt // "-"), (.mergeCommit.oid // "-")] | @tsv' || return 1
  # an unreadable BODY is not an empty one: it would read as "no record marker exists" (F2 the third
  # time). The `.unread` sentinel keeps that distinguishable at the review_record predicate.
  store_read "$dir" body.txt \
    "$GH" pr view "$pr" --repo "$REPO" --json body --jq '.body // ""'
  # markers ACCUMULATE in the comments across a fix round; that is where the round's history lives.
  # ⛔ THE COMMENTS ARE FETCHED IN THE PRODUCER'S OWN FRAME, WITH THEIR AUTHOR (fresh-context review,
  # round 8 — BLOCKING, the false-PASS class). This read used to be
  #   `.comments[] | "<<<COMMENT>>>\n" + (.body // "")`
  # — no author at all, so NOTHING downstream could apply the admission rule the repo's own required
  # check applies to exactly this artifact: on a public repo any account can post one line naming the
  # public head sha, and this verifier would report `PASS review_record` + `PASS review_bound` and
  # `VERDICT: ALL-MET`, exit 0 — the value the #4016 capstone closes on — over a hand-typed comment.
  # The frame and the jq are `check-pipeline-compliance.sh`'s OWN (`REVIEW_COMMENTS_JQ`, `:707`), copied
  # rather than re-invented, so the two readers admit the same artifact for the same reasons: one record
  # per comment, `<author_association>\x1f<body>\x1e`. The 0x1e/0x1f bytes are stripped from the body
  # first, so a comment cannot forge a record boundary.
  # ⛔ THE FILTER TRAVELLED WITH THE GATE; ITS ENDPOINT DID NOT (fresh-context review, round 10 —
  # BLOCKING, measured). This read was `pr view --repo … --json comments`, which answers a JSON OBJECT
  # (`{"comments":[…]}` — exactly the shape the `pr.meta` read above assumes with `.number`/`.state`)
  # in gh's CAMELCASE field spelling. `REVIEW_COMMENTS_JQ` is written for REST
  # `repos/<o>/<r>/issues/<n>/comments`: ARRAY root, SNAKE_CASE fields. On the endpoint it was pointed
  # at it failed TWICE, independently — `.[]` yields the comment ARRAY, so `.author_association` is a jq
  # RUNTIME error (`expected an object but got: array`), and even under `.comments[]` the REST key does
  # not exist there, so the association read `null` and `record_markers` emitted `DENY` for EVERY
  # comment marker. Either alone made `store_read` return 2 and write `comments.txt.unread`;
  # `analyse` short-circuits on `rc_unread` BEFORE the `record.json` fallback, so review_record,
  # review_bound, fix_round and green_gated were INCONCLUSIVE on every LIVE run and `VERDICT: ALL-MET`
  # was unreachable live — the one value the #4016 capstone closes on. The suite could not see it: every
  # case is `--from-snapshot`, and the fixtures hand-write `comments.txt` in the frame the READER wants,
  # so the producer-side expression never executed (the `gh`-shim case at the end of the suite exists to
  # keep that from recurring). The fix is to take the ENDPOINT with the filter, which is the same read
  # the required check performs (`check-pipeline-compliance.sh:6021`, `issues/$PR_NUMBER/comments`) — so
  # one artifact, one frame, and no field-spelling translation to drift (`--paginate`: a PR past the
  # first page of comments is read whole, as the gate reads it).
  store_read "$dir" comments.txt \
    "$GH" api "repos/$REPO/issues/$pr/comments?per_page=100" --paginate \
      --jq '.[] | "\(.author_association)\u001f\(.body | gsub("[\u001e\u001f]"; ""))" + "\u001e"'

  rec="$HOME/.pi/agent/reviews/${OWNER}-${RNAME}-${pr}.json"
  legacy="$HOME/.pi/agent/reviews/${pr}.json"
  if [ -s "$rec" ]; then cp "$rec" "$dir/record.json"
  elif [ -s "$legacy" ]; then cp "$legacy" "$dir/record.json"; fi

  rail="$RAIL_DIR/auto-${OWNER}-${RNAME}-${pr}.out"
  [ -s "$rail" ] && cp "$rail" "$dir/rail.out" 2>/dev/null

  # ⛔ A PR-NUMBER-KEYED MARKER IS NOT PROOF FOR *THIS* REPO (review finding F4, and the ruling this
  # repo already recorded at `chain-merge.sh:246-251`): `state/merged-<PR>.done` and
  # `logs/merge-<PR>.log` carry NO repo and `$O/state` is shared by every repo on the box, so a merge
  # of `tortoise#<same n>` reads as this PR's landing. The confirmation `chain-merge.sh` uses is a
  # repo-scoped read of the PR itself — which this file already holds (`mergedAt` in pr.meta). So the
  # marker is admitted only when its own mtime is consistent with THAT merge: outside the window it is
  # ignored and the route stays unknown rather than being attributed to the wrong landing.
  local mt mt_s mt_e mt_state=""
  mt="$(awk -F'\t' 'NR == 1 { print $3 }' "$dir/pr.meta" 2>/dev/null)"
  mt_s="$(iso_epoch "$mt")"
  # ⛔ AN UNUSABLE WINDOW IS NOT AN OPEN ONE (fresh-context review round 6, P3). This guard used to be
  # `[ -n "$mt_s" ]`: when `mergedAt` could not be parsed the whole window test was SKIPPED and a
  # PR-number-keyed marker was admitted unconditionally — the opposite of what the comment eight lines
  # up says ('a silent empty answer from either must read as unusable rather than as in window'), and
  # exactly the fail-open direction F4 exists to close. Three states now, and only `ok` can admit.
  case "$mt" in
    ""|-) : ;;
    *) if [ -n "$mt_s" ]; then mt_state=ok; else mt_state=unusable; fi ;;
  esac
  if [ "$mt_state" = ok ]; then
    mt_e=$((mt_s + CHAIN_MARKER_WINDOW))
    mt_s=$((mt_s - CHAIN_MARKER_WINDOW))
  fi
  chain_artifact() { # chain_artifact <path> <store-name>
    [ -f "$1" ] || return 1
    local f_ts f_s
    f_s=""
    if [ "$mt_state" = unusable ]; then
      : > "$dir/${2}.unusable"
      return 1
    fi
    if [ "$mt_state" = ok ]; then
      f_ts="$(file_mtime "$1")"
      f_s="$(iso_epoch "$f_ts")"
      [ -n "$f_s" ] || return 1
      if [ "$f_s" -lt "$mt_s" ] || [ "$f_s" -gt "$mt_e" ]; then
        : > "$dir/${2}.out-of-window"
        return 1
      fi
    fi
    case "$2" in
      chain.merged) : > "$dir/chain.merged" ;;
      *) cp "$1" "$dir/$2" 2>/dev/null || return 1 ;;
    esac
    return 0
  }
  chain_artifact "$O/state/merged-${pr}.done" chain.merged
  chain_artifact "$O/state/lanemerge-${pr}.verdict" chain.verdict
  chain_artifact "$O/logs/merge-${pr}.log" merge.log

  sha="$(awk -F'\t' 'NR == 1 { print $4 }' "$dir/pr.meta" 2>/dev/null)"
  case "$sha" in
    ""|"-") : ;;
    *) fetch_commit "$dir" "$sha" ;;
  esac
  # the PR's own commit list: the LAST line is its tip, and that is what "nothing was pushed after
  # the review" is anchored on (a TREE comparison is not — see the header's #3996 counter-example).
  store_read "$dir" pr-commits.tsv \
    "$GH" api "repos/$REPO/pulls/$pr/commits?per_page=100" --paginate --jq '.[].sha' || :
  return 0
}

# ⛔ NOTHING IS REDIRECTED STRAIGHT ONTO AN ARTIFACT PATH (review finding F2). The shell creates and
# truncates the target BEFORE `gh` runs, so a 403 left a 0-byte file that every reader below scored as
# a MEASURED fact — a failed read became "the head carried no check-run". Writes go to `.tmp` and are
# `mv`d only on rc 0; a failed read leaves an explicit `<name>.unread` and NO artifact, so "did not
# read" and "read, and it was empty" stay distinguishable in every direction.
store_read() { # store_read <dir> <name> <command…>  → 0 stored (MAY be empty — a measured zero) · 2 UNREAD
  # ⛔ THERE IS NO THIRD RESULT (fresh-context review, round 7, P3): this contract used to document
  # `1 · STORED but empty-ish`, which the implementation NEVER returns and no caller distinguishes —
  # an empty artifact here is a FACT ("the endpoint answered, and there is nothing attached"), which
  # the predicates read for themselves (`surface_verdicts` prints `surface/empty` for it). Only
  # "could not read" is a distinct state, and it is the `.unread` sentinel plus this rc.
  local dir="$1" name="$2"; shift 2
  local tmp="$dir/.tmp-$name"
  : > "$tmp" 2>/dev/null || return 2
  if "$@" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$dir/$name" 2>/dev/null || return 2
    rm -f "$dir/$name.unread" 2>/dev/null
    return 0
  fi
  rm -f "$tmp" "$dir/$name" 2>/dev/null
  : > "$dir/$name.unread"
  return 2
}

fetch_commit() { # fetch_commit <dir> <sha>
  local dir="$1" sha="$2"
  store_read "$dir" "commit-${sha}.tsv" \
    "$GH" api "repos/$REPO/commits/$sha" \
      --jq '[.sha, .commit.tree.sha, ([.parents[].sha] | join(","))] | @tsv'
}

fetch_head_surface() { # fetch_head_surface <dir> <head_sha>
  local dir="$1" sha="$2" rc_runs=0
  case "$sha" in ""|"-") return 1 ;; esac
  fetch_commit "$dir" "$sha" || return 1
  # run id -> WORKFLOW NAME and attempt number, ONE read per head (see the grouping note above).
  # ⛔ A FAILED RUNS READ IS NOT AN EMPTY ONE (review finding F2/A): without the run ids every group
  # falls back to `app:<slug>`, which merges two workflows that publish the same job name — so the
  # masking case 8 exists for would become reachable through a rate limit, in the GREEN direction.
  store_read "$dir" "runs-${sha}.tsv" \
    "$GH" api "repos/$REPO/actions/runs?head_sha=${sha}&per_page=100" --paginate \
      --jq '.workflow_runs[] | [.id, .name, .run_attempt, (.path // "")] | @tsv' || rc_runs=$?
  # `filter=all` is PINNED: the endpoint's default is not all (measured: 26 of 40 on a real commit),
  # so a bare read silently drops every re-run and can report a red head green.
  # `started_at` is captured because it is what separates "this check had not voted yet when the
  # landing happened" from "this check did not exist until after the merge" (review finding F1).
  store_read "$dir" "checkruns-${sha}.tsv" \
    "$GH" api "repos/$REPO/commits/$sha/check-runs?per_page=100&filter=all" --paginate \
      --jq '.check_runs[] | [.id, (.app.slug // "-"), .name, .status, (.conclusion // "-"), (.completed_at // "-"), (.details_url // "-"), (.started_at // "-")] | @tsv' || return 1
  [ "$rc_runs" -eq 0 ] || return 1
  return 0
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Record markers — the recorder's own line, shape taken from scripts/record-review.sh:4887
#   review recorded: reviews/<pr>.json verdict=<v> @ <40hex> [diff=<64hex>] (<owner/repo>) ...
# ORDERING: the LAST marker wins, and the BODY is read AFTER the comments. The recorder writes its
# statement into the body, so a body line is the recorder's CURRENT word; comments are history. Both
# are read because a body edit can drop an older marker, and the fix-round history lives in whichever
# file the recorder appended to (verified on PR #4025, whose body holds both the `not-clean` and the
# later `clean` line).
# ════════════════════════════════════════════════════════════════════════════════════════════════
# ⛔ A MARKER MUST NAME *THIS* REPO (review finding F3). The canonical recorder refuses a marker that
# names another repo — `scripts/record-review.sh:4889`: "PR numbers collide across repos, so this is
# refused rather than adopted" — and the first cut of this reader stopped at the sha, so a marker for
# `(someone-else/other-repo)` made an UNREVIEWED head read as reviewed at exactly the right head. The
# `(<owner/repo>)` group is therefore REQUIRED and compared folded (GitHub slugs are case-insensitive);
# a marker that names no repo, or another repo, is not evidence — it is SKIPPED and REPORTED, never
# silently dropped.
# The CHANNEL is tagged because the recorder treats the two differently: the BODY is its own CURRENT
# statement (record-review.sh:4896-4899, "the poster APPENDS … keep the LAST"), while a comment is a
# PUBLIC artifact any account can write.
# ⛔ SO A COMMENT MARKER IS ADMITTED, NOT MERELY LABELLED (fresh-context review, round 8 — BLOCKING,
# the false-PASS class this file exists to eliminate). The first cut fetched the comments with NO author,
# admitted any line of the right shape, recorded `sig=` as prose (`sig=absent`) and never let it decide
# anything — so a hand-typed comment at the public head sha produced `PASS review_record` AND
# `PASS review_bound`, i.e. `VERDICT: ALL-MET` and exit 0, the value #4016's capstone closes on. The
# repo had ALREADY decided this artifact: `check-pipeline-compliance.sh` check (c) admits a comment
# marker only from `author_association ∈ OWNER|MEMBER|COLLABORATOR` (`:701`, `:763`) and only with a
# `sig=` that verifies under the gate key wherever one resolves (`review_marker_sig_ok`, `:713`, `:769`);
# its own simulations `pass 1224g`/`1224h` assert that an UNSIGNED marker comment — and an untrusted
# author — are REFUSED, and `record-review.sh:2406` enforces the same author set. That rule is applied
# here, unchanged, in the same order, and the residual is the gate's own: with NO key resolvable on the
# box the association is the admission (a CI runner carries no key, so a sig-only arm would be inert
# there — the defect #1224 exists to remove) — and that is SAID in the detail, never implied.
# ⛔ With a key resolvable, an unsigned or non-verifying `sig=` is NOT evidence (fail closed).
gate_key() { # the HMAC key, env first then the producer's key file — check-pipeline-compliance.sh:878
  local k="${AI_REVIEW_GATE_KEY:-}"
  if [ -z "$k" ] && [ -f "${HOME:-/nonexistent}/.pi/agent/.ai-review-gate-key" ]; then
    k="$(cat "${HOME:-/nonexistent}/.pi/agent/.ai-review-gate-key" 2>/dev/null || true)"
  fi
  printf '%s' "$k" | tr -d '[:space:]'
}
marker_sig_ok() { # <marker line> → 0 iff its own trailing ` sig=<64hex>` verifies under the gate key
  local text="$1" txt sig exp
  [ -n "$GATE_KEY" ] || return 1
  [ -n "$OPENSSL_OK" ] || return 1
  case "$text" in *" sig="*) ;; *) return 1 ;; esac
  txt="${text% sig=*}"; sig="${text##* sig=}"
  case "$sig" in ''|*[!0-9a-f]*) return 1 ;; esac
  [ "${#sig}" -eq 64 ] || return 1
  exp="$(printf '%s' "$txt" | command openssl dgst -sha256 -hmac "$GATE_KEY" 2>/dev/null \
    | command awk '{print $NF}' || true)"
  [ -n "$exp" ] && [ "$exp" = "$sig" ]
}
# resolved ONCE, before any predicate runs, so every reader below asks the same question
GATE_KEY="$(gate_key)"
OPENSSL_OK=""
command -v openssl >/dev/null 2>&1 && OPENSSL_OK=1
# ⛔ THE MARKER'S WHOLE-LINE GRAMMAR, IN ONE PLACE (fresh-context review, round 11 — BLOCKING, the
# false-PASS class). A marker is an ARTIFACT only when it is the WHOLE line (`BODY`) / the WHOLE comment
# body (`COMMENT`), and this is the repo's own predicate, not a shape invented here:
#   * `scripts/record-review.sh:8157-8179` PRODUCES exactly this line;
#   * `:6256` (`RB_RE`) reads it back as a whole line;
#   * `scripts/check-pipeline-compliance.sh:523` (`REVIEW_RECORD_MARKER_RE`) is `^…$`-anchored and its
#     comment arm applies it to the comment's WHOLE body with trailing whitespace trimmed (`:756-760`),
#     so a marker embedded in a longer comment — or written as a list item — is REFUSED there;
#   * `record-review.sh:2360-2377` records that refusal as a fixed-twice defect, naming the reachable
#     no-attacker case: "a comment whose FIRST LINE is the marker and which continues below".
# That predicate is applied here, unchanged: a marker that is not the whole artifact is NOT evidence.
# ⛔ `[0-9a-f]+`, NOT `{40}`/`{64}`: interval expressions are absent from some awks this repo runs (macOS
# one-true-awk), and the exact lengths are already enforced by the field parse below (40 for the sha) and
# by `marker_sig_ok` (64 for the sig). What this expression decides is the SHAPE and the LINE BOUNDARY.
# The trailer alternatives are the recorder's OWN fields — `findings=`/`note=` (not-clean only) and
# ` sig=` — so the free-text `note=` still matches while ordinary prose does not.
marker_whole_re() { # <pr> → the anchored ERE a marker must satisfy as a WHOLE body / whole line
  printf '%s' '^review recorded: reviews/'"$1"'\.json verdict=(clean|clean-micro|clean-low|not-clean) @ [0-9a-f]+( diff=[0-9a-f]+)? \([A-Za-z0-9._-]+/[A-Za-z0-9._-]+\)( findings=[^"]*)?( sig=[0-9a-f]+)?$'
}
record_markers() { # record_markers <dir> <pr>
  #   MARK <chan> <verdict> <sha> <repo> <assoc|-> <marker line, verbatim>   ← this repo, admissible shape
  #   SKIP <chan> <sha12> <repo-or-(none)>   a marker that names no repo, or another repo
  #   DENY <chan> <sha12> <assoc|->          a COMMENT whose author is not OWNER/MEMBER/COLLABORATOR
  #   NOTWHOLE <chan>                        a marker-SHAPED artifact the whole-artifact rule refused
  local dir="$1" pr="$2"
  {
    # ── the COMMENT channel: the producer's frame, one `<author_association>\t<body>` per comment ──
    # ⛔ ONE RECORD PER COMMENT BODY, NOT ONE PER LINE (fresh-context review, round 11 — BLOCKING). This
    # used to `split(body, L, "\n")` and hand every line of every comment to the parser, which made any
    # line of any trusted comment evidence: a trusted author QUOTING a marker inside a longer comment ("…
    # the recorder said:\n<marker>\nlooks right") satisfied `review_record` AND `review_bound` here while
    # the required check refuses that comment outright — the one artifact direction this file and its header
    # forbid. The body is now handed over only when it IS the text, i.e. a single line after trailing
    # whitespace is trimmed (GitHub bodies arrive CRLF, and a client may append a newline).
    # ⛔ A MARKER-SHAPED MULTI-LINE BODY IS *REPORTED*, NOT DROPPED: a silent refusal reads as "no record"
    # and the next reader re-derives the same question (the report names it, `nonwhole_markers`).
    # ⛔ `sub(/^[\n\r]+/)` IS LOAD-BEARING: `jq -r` writes a NEWLINE after each record, so every record
    # but the first would begin with one and the AUTHOR field would read "\nOWNER" — refusing a marker
    # from a trusted author for a reason invisible in the report (measured while building this read).
    [ -s "$dir/comments.txt" ] && awk -v RS='\036' '
      {
        sub(/^[\n\r]+/, "")
        i = index($0, "\037")
        if (i == 0) { assoc = "-"; body = $0 } else { assoc = substr($0, 1, i - 1); body = substr($0, i + 1) }
        sub(/[[:space:]]+$/, "", body)
        if (body == "") next
        if (index(body, "\n") != 0 || index(body, "\r") != 0) {
          if (index(body, "review recorded: reviews/") != 0) printf "NOTWHOLE\tCOMMENT\n"
          next
        }
        printf "COMMENT\t%s\t%s\n", assoc, body
      }' "$dir/comments.txt"
    # the BODY last, and tagged, so "the recorder's current word" is distinguishable from history.
    # ⛔ `awk`, NOT `sed 's/^/COMMENT\t/'` (fresh-context review, round 7, P3). POSIX says an escaped
    # ORDINARY character in a sed replacement stands for itself, so a BSD/macOS sed emits `COMMENTt…`
    # and `BODYt…` (GNU's `\t`→TAB is an extension); with `-F'\t'` and
    # `index(line, "review recorded: …") != 1` NO marker would ever parse on a Mac, leaving
    # review_record/fix_round/review_bound/green_gated permanently INCONCLUSIVE on the one platform
    # the capstone is required on — while the Linux suite stayed green. `check-portability-traps.sh`
    # has no `\t`-in-sed row, so nothing else would have caught it. `awk`'s `printf "X\t%s\n"` is the
    # portable form (verified: identical output on gawk, mawk, nawk and `awk --posix`).
    printf 'BODY\t-\t\n'
    [ -s "$dir/body.txt" ] && awk '{ printf "BODY\t-\t%s\n", $0 }' "$dir/body.txt"
  } | MARKER_WHOLE_RE="$(marker_whole_re "$pr")" awk -F'\t' -v pr="$pr" -v want="$REPO" '
    # ⛔ THE GRAMMAR ARRIVES THROUGH `ENVIRON`, NOT `-v` (round 11). A `-v` assignment is escape-PROCESSED
    # by awk (its value is read like a string literal), so `\.` / `\(` in the ERE would be collapsed by
    # some awks to `.` / `(` and the anchors would weaken silently — the exact class of platform-split
    # this file has been bitten by before (the round-10 `\x2d` class). `ENVIRON` carries the bytes verbatim; the
    # four awks this repo runs (gawk, mawk, nawk/one-true-awk, `gawk --posix`) were measured to compile it
    # identically.
    BEGIN { fold = tolower(want); whole = ENVIRON["MARKER_WHOLE_RE"] }
    {
      chan = $1
      # ⛔ A CHANNEL WORD OUTSIDE THE FRAME SET IS A CORRUPT FRAME, NOT EVIDENCE (fresh-context review,
      # round 9). The frame is OURS — `COMMENT|BODY TAB assoc TAB marker` — so anything else means a field
      # leaked its boundary (a newline inside an author, the shape M23 pins) and the remainder of the line
      # arrived as a channel nobody wrote. Since round 9 the channel is no longer a filter applied once in
      # `last_marker`, so without this an invented channel would reach the ADMISSION instead: a verifying
      # `sig=` admits a marker whose channel is not `COMMENT`-or-`BODY` (a comment is admitted on its
      # signature), which is how the M23 pin first stopped discriminating.
      if (chan == "NOTWHOLE") { print; next }   # a refusal decided upstream (the COMMENT whole-body rule)
      if (chan != "COMMENT" && chan != "BODY") next
      # the channel and the author come from the FRAME; everything after them is the marker as it was
      # written (tabs included), because a signature covers the bytes the recorder signed
      line = $0
      sub(/^[^\t]*\t/, "", line)
      k = index(line, "\t")
      assoc = (k ? substr(line, 1, k - 1) : "-")
      line  = (k ? substr(line, k + 1) : line)
      # ⛔ THE PREFIX TOLERANCE IS GONE (fresh-context review, round 11 — BLOCKING), and with it the round-10
      # `[[:space:]>*+-]` strip. That strip existed to tolerate a LIST ITEM (`- review recorded: …`) — and
      # a list item is exactly what the required check REFUSES, because its comment arm matches the
      # `^…$`-anchored `REVIEW_RECORD_MARKER_RE` against the WHOLE comment body and its body arm does the
      # same per line. Tolerating it here admitted `- review recorded: …` while the gate threw the same
      # comment away, i.e. `VERDICT: ALL-MET` over an artifact the only required check ignores. The two
      # readers now agree, and the round-10 portability question (`\x2d` being a gawk-only escape) is gone
      # with the strip rather than fixed inside it — there is no prefix to strip.
      # the recorder writes: review recorded: reviews/<pr>.json verdict=V @ <40hex> (owner/repo)
      if (index(line, "review recorded: reviews/" pr ".json verdict=") != 1) {
        # ⛔ A MARKER FOR THIS PR EMBEDDED IN SOMETHING ELSE IS REPORTED (round 11). Its two real shapes are
        # the ones the finding named: a trusted author QUOTING the marker inside a longer comment, and a
        # LIST ITEM. Both are refused by the required check and by this reader now — silently dropping them
        # here would read as "there is no record", which is the report-blindness the whole-artifact rule is
        # NOT allowed to introduce.
        if (index(line, "review recorded: reviews/" pr ".json verdict=") != 0) printf "NOTWHOLE\t%s\n", chan
        next
      }
      # ⛔ THE WHOLE-ARTIFACT RULE, applied to BOTH channels (round 11 — BLOCKING). `whole` is
      # the anchored ERE from `marker_whole_re` (see its header): the same predicate `record-review.sh` produces
      # against and `check-pipeline-compliance.sh` admits against. Anything that only CONTAINS the marker
      # — trailing prose, a quoted marker, a list item — is refused and REPORTED, never silently dropped.
      if (line !~ whole) { printf "NOTWHOLE\t%s\n", chan; next }
      rest = line
      sub(/^review recorded: reviews\/[^ ]* verdict=/, "", rest)
      v = rest; sub(/ .*$/, "", v)
      if (v != "clean" && v != "clean-micro" && v != "clean-low" && v != "not-clean") next
      # ⛔ THE FIRST ` @ `, NOT THE LAST (fresh-context review, round 9 — P2, MEASURED). The greedy
      # `^.* @ ` walked to the LAST ` @ ` in the line, and that line TRAILER IS FREE TEXT:
      # record-review.sh splices the recorder FINDINGS_NOTE verbatim after the sha
      # (`… @ <40hex> (o/r) findings=<note>`, :8172, which rejects only a quote, a backslash and control
      # bytes). A note reading `refused @ round 1` therefore left `round 1` as the sha, the 40-hex guard
      # failed, and `next` dropped the marker SILENTLY — and the note trailer exists ONLY on not-clean
      # markers, so the markers this ate were exactly the refusals whose loss flips the verdict: with the
      # refusal at the same head as an earlier clean the report read `VERDICT: ALL-MET`, exit 0, over a
      # standing refusal (the F2n/M10 false-PASS class, reopened through the trailer). Anchored on the
      # marker own `<verdict> @ <sha>` frame — `rest` starts at the verdict word — so trailer text cannot
      # reach the sha field at all.
      if (rest !~ /^[^ \t]+ @ [0-9a-f]+( |$)/) next
      s = rest; sub(/^[^ \t]+ @ /, "", s); sub(/ .*$/, "", s)
      if (length(s) != 40 || tolower(s) !~ /^[0-9a-f]+$/) next
      repo = ""
      # the FIRST parenthesised slug-shaped group is the marker repo; text after it (findings=, sig=)
      # cannot match, because a slug-shaped group has no spaces
      if (match(line, /\([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\)/)) {
        repo = substr(line, RSTART + 1, RLENGTH - 2)
      }
      if (repo == "")            { printf "SKIP\t%s\t%s\t(none)\n", chan, substr(s, 1, 12); next }
      if (tolower(repo) != fold) { printf "SKIP\t%s\t%s\t%s\n",     chan, substr(s, 1, 12), repo; next }
      # ⛔ THE AUTHOR ADMISSION, on the COMMENT channel only (check-pipeline-compliance.sh:763): a body
      # needs write access to the PR, a comment does not — "on a public repo any account can comment,
      # so an unattested commenter is not evidence". Left to the caller so the refusal can quote it.
      if (chan == "COMMENT" && assoc != "OWNER" && assoc != "MEMBER" && assoc != "COLLABORATOR") {
        printf "DENY\t%s\t%s\t%s\n", chan, substr(s, 1, 12), assoc; next
      }
      printf "MARK\t%s\t%s\t%s\t%s\t%s\t%s\n", chan, v, s, repo, assoc, line
    }
  '
}

# The admission that decides whether a matched marker is EVIDENCE: the author (already applied in the
# parser, reported as DENY) and the SIGNATURE, which needs openssl so it is settled here.
admitted_marks() { # <dir> <pr> → "MARK <chan> <verdict> <sha> <auth>" · "SKIP …" · "DENY <reason>"
  local dir="$1" pr="$2" line kind rest chan v sha repo assoc text auth
  record_markers "$dir" "$pr" | while IFS= read -r line; do
    IFS='	' read -r kind rest <<<"$line"
    case "$kind" in
      MARK)
        IFS='	' read -r chan v sha repo assoc text <<<"$rest"
        if marker_sig_ok "$text"; then
          auth="sig"
        else
          case "$chan" in
            BODY)
              # the body needs write access, and the gate keeps its legacy unsigned tolerance for it
              # (check-pipeline-compliance.sh's body arm) so an in-flight PR is not stranded
              auth="body" ;;
            COMMENT)
              if [ -n "$GATE_KEY" ]; then
                printf 'DENY\tCOMMENT\t%s\tits sig= does not verify under this box gate key (no sig= at all, a different key, or edited after minting) — a comment is not evidence by shape (the gate: pass 1224g)\n' "$(printf '%s' "$sha" | cut -c1-12)"
                continue
              fi
              auth="association" ;;
            *) auth="unknown" ;;
          esac
        fi
        printf 'MARK\t%s\t%s\t%s\t%s\n' "$chan" "$v" "$sha" "$auth" ;;
      SKIP) printf 'SKIP\t%s\n' "$rest" ;;
      DENY)
        IFS='	' read -r chan sha assoc <<<"$rest"
        printf 'DENY\t%s\t%s\tits author_association is %s, not OWNER/MEMBER/COLLABORATOR — on a public repo any account can comment, so an unattested commenter is not evidence (the gate own rule, pass 1224h)\n' \
          "$chan" "$sha" "${assoc:-(absent)}" ;;
    esac
  done
}

# ⛔ THE CHANNELS ARE ORDERED BY RECENCY, NOT BY CHANNEL PRIORITY (fresh-context review, round 9 —
# P2, MEASURED). Channel priority said "any body marker beats every comment marker", but the PRODUCER
# posts the comment FIRST and the body second, and the body write is BEST-EFFORT
# (`record-review.sh:8420` `post_review_evidence_comment … || true`, then `post_marker`): a body PATCH
# that failed — the exit-5 path the pending/flush machinery exists for — leaves a STALE body marker while
# the comment carries the newest record, and a later body edit can drop the newest marker outright. On a
# landing whose body said `not-clean@H1` and whose comment said `clean@H2` (H2 the PR tip) the reader
# reported `FAIL review_record "the standing record at head … is NOT-CLEAN"` plus a `did not converge`
# fix_round, exit 1 — the false-FAIL class the header says teaches readers to ignore the instrument.
# RECENCY IS THE MARKER'S POSITION IN THE PR'S OWN (linear) COMMIT LIST, which a lost body write cannot
# rewrite; the channel is the TIEBREAK at an equal head, where the recorder's "the body is the current
# word" rule still holds (the body is written last). A head that is not in the commit list is read as
# the OLDEST — `review_bound` already FAILs a marker at a revision the PR never carried.
# Output: "verdict TAB sha TAB chan TAB auth", oldest first. `sort` is used rather than an awk
# selection sort so the ordering rule is one portable expression.
markers_ordered() { # markers_ordered <dir> <pr> [BODY|COMMENT|*]
  admitted_marks "$1" "$2" | awk -F'\t' -v ch="${3:-*}" -v commits="$1/pr-commits.tsv" '
    BEGIN { n = 0; while ((getline l < commits) > 0) { n++; idx[l] = n } }
    $1 != "MARK" { next }
    ch != "*" && $2 != ch { next }
    {
      i = ($4 in idx) ? idx[$4] : 0
      cr = ($2 == "BODY") ? 2 : 1      # the comment is written FIRST, the body last
      seq++
      printf "%08d\t%02d\t%08d\t%s\t%s\t%s\t%s\n", i, cr, seq, $3, $4, $2, $5
    }' | LC_ALL=C sort | cut -f4-
}

# this repo, one channel: "verdict TAB sha TAB auth", oldest first
markers_from() {
  markers_ordered "$1" "$2" "${3:-*}" | cut -f1,2,4
}

nonwhole_markers() { # → "channel" for every marker-SHAPED artifact the whole-artifact rule refused
  # ⛔ REPORTED, NOT DROPPED (round 11). A refusal a reader cannot see is indistinguishable from "there is
  # no record", which is how a marker-in-a-longer-comment gets pasted again next round.
  record_markers "$1" "$2" | awk -F'\t' '$1 == "NOTWHOLE" { print $2 }' | sort -u | paste -sd ',' -
}

# the recorder's CURRENT word is the NEWEST admitted marker, on whichever channel carried it
last_marker() { # → "verdict TAB sha TAB source TAB auth"; empty when nothing admitted
  local m
  m="$(markers_ordered "$1" "$2" '*' | tail -1)"
  [ -n "$m" ] || return 1
  printf '%s\t%s\t%s\t%s\n' "$(printf '%s' "$m" | cut -f1)" "$(printf '%s' "$m" | cut -f2)" \
    "$(printf '%s' "$m" | cut -f3 | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')" \
    "$(printf '%s' "$m" | cut -f4)"
}

skipped_markers() { # → "channel:sha:repo" for the markers refused as foreign, or empty
  record_markers "$1" "$2" | awk -F'\t' '$1 == "SKIP" { print $2 ":" $3 ":" $4 }' | paste -sd ',' -
}

denied_markers() { # → "why" for every marker-shaped artifact refused by admission, or empty
  admitted_marks "$1" "$2" | awk -F'\t' '$1 == "DENY" { print $4 }' | paste -sd ' · ' -
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# The as-of-merge surface. awk, not bash: a composite group key is an awk associative array, and
# doing this with parallel bash-3.2 arrays is where an off-by-one starts reading a stranger's verdict
# as green. Output per group:  <group> TAB <red|green|nonred|pending|novote|empty> TAB <conclusion> TAB <completed_at>
# ════════════════════════════════════════════════════════════════════════════════════════════════
surface_verdicts() { # surface_verdicts <dir> <head_sha> <merged_at>
  local dir="$1" sha="$2" merged="$3"
  local cr="$dir/checkruns-${sha}.tsv" runs="$dir/runs-${sha}.tsv"
  [ -s "$cr" ] || return 1
  {
    printf '==RUNS==\n'
    [ -s "$runs" ] && cat "$runs"
    printf '==CHECKS==\n'
    cat "$cr"
  } | awk -F'\t' -v merged="$merged" '
    function runid_of(url,   a) {
      if (url !~ /github\.com\/.*\/actions\/runs\//) return ""
      a = url; sub(/.*\/actions\/runs\//, "", a); sub(/\/.*$/, "", a); return a
    }
    # GREEN is an ALLOW-LIST and every other completed conclusion is RED — the rail adopted that
    # polarity after an unrecognised conclusion fell through a gap and a merge went ahead on it.
    # `cancelled`/`stale` are non-red: they are not verdicts about the code.
    function classify(status, conc) {
      if (status != "completed") return "pending"
      if (conc == "success" || conc == "neutral" || conc == "skipped") return "green"
      if (conc == "cancelled" || conc == "stale") return "nonred"
      return "red"
    }
    $0 == "==RUNS==" { sect = "runs"; next }
    $0 == "==CHECKS==" { sect = "checks"; next }
    sect == "runs" && NF >= 2 { wf[$1] = ($4 != "" ? $4 : $2); next }
    sect == "checks" && NF >= 7 {
      id = $1 + 0; app = $2; name = $3; status = $4; conc = $5; done_at = $6; url = $7; started_at = $8
      rid = runid_of(url); w = (rid != "" ? wf[rid] : "")
      if (w == "") w = "app:" app
      g = w "/" name
      seen[g] = 1
      # ⛔ THE NEWEST ATTEMPT THAT EXISTED AT THE MERGE DECIDES WHAT THE LANDING SAW — NOT THE NEWEST ONE
      # THAT VOTED (fresh-context review, round 4 F3 — measured). The previous rule took the newest
      # COMPLETED attempt by the merge, so a group with `success@04:00` then a newer `in_progress`
      # (started 05:00) and a merge at 05:05 was reported GREEN with the detail "newest attempt per
      # app/workflow/job" — while the newest attempt had not voted at all. That is the header own
      # invariant ("the newest attempt of EVERY group was GREEN and completed") stated falsely, in the
      # flattering direction, on the predicate the capstone is closed on.
      #
      # "Existed at the merge" is read fail-closed, because the API does not always say:
      #   completed     → it existed if it had voted by mergedAt, or was already running then
      #   NOT completed → it exists, UNLESS its own `started_at` proves it began AFTER mergedAt
      # ⛔ `started_at` LATER THAN mergedAt IS NOT "IT DID NOT EXIST" AND NOT "IT EXISTED" (round 6, P2).
      # The previous expression defaulted EVERY non-completed attempt to `existed` and ignored a
      # `started_at` that was present and later than the merge, so a re-run created four hours AFTER a
      # landing read as `waited` → FAIL "did not wait for" — a FALSE FAIL whose sentence is the
      # description of the `later` bucket itself, and whose verdict flips the moment that post-merge
      # job happens to finish. A null `started_at` (a `queued` run) still reads as "existed": the absence of a
      # timestamp is never read as "it did not exist yet".
      started_late = (started_at != "-" && started_at != "" && started_at > merged)
      # ⛔ ONLY A VERDICT KNOWN BY THE MERGE COUNTS (fresh-context review, round 5 F1 — BLOCKING, a
      # false PASS). A COMPLETED attempt whose `completed_at` is after `mergedAt` had not voted then,
      # even if its `started_at` was before: classifying it by its final conclusion recorded a re-run
      # that started 05:00 and went green 05:24 on a 05:05 merge as `green` while the flag below
      # recorded the same attempt as a LATE green. The two disagreed, and the standing verdict was the
      # one deciding the exit code. Measured: identical fixture, only `started_at` changed →
      # 05:00 gave `VERDICT: ALL-MET` exit 0; 05:20 gave the correct FAIL.
      voted_by_merge = (status == "completed" && done_at != "-" && done_at != "" && done_at <= merged)
      if (status == "completed")
        existed = (voted_by_merge || (started_at != "-" && started_at != "" && started_at <= merged))
      else
        existed = !started_late
      if (existed && (!(g in nid) || id > nid[g])) {
        nid[g] = id; ndone[g] = done_at
        if (voted_by_merge) { ncls[g] = classify(status, conc); nconc[g] = conc }
        else                { ncls[g] = "pending";              nconc[g] = "-"  }   # it existed, it had not voted
      }
      # the green timing is about the whole HISTORY of the job, so it looks at every attempt
      if (classify(status, conc) == "green") {
        egreen[g] = 1
        if (done_at == "-" || done_at == "" || done_at > merged) green_late[g] = 1
        else green_before[g] = 1
      }
      next
    }
    END {
      n = 0
      for (g in seen) {
        # ── the standing verdict of the group, three ways, each a fact about the merge ──────────
        #   green/nonred/red   the newest attempt that existed by mergedAt had that verdict
        #   waited             such an attempt existed and had NOT voted (in flight, or queued with no
        #                      start timestamp — the API does not distinguish them, so neither do we)
        #   later              no attempt existed by mergedAt at all: a post-merge job, not part of
        #                      this gate
        if (g in nid) v = (ncls[g] == "pending" ? "waited" : ncls[g])
        else          v = "later"
        # field 4 is the GREEN TIMING the red bucket is split on — measured, never assumed:
        #   never    no green attempt on this job at all
        #   late     a green attempt exists but completed after mergedAt (it gated nothing here)
        #   earlier  a green completed BEFORE the merge and a NEWER attempt was the red
        if (!(g in egreen))          et = "never"
        else if (g in green_before)  et = "earlier"
        else                         et = "late"
        print g "\t" v "\t" ((g in nconc) ? nconc[g] : "-") "\t" et "\t" ((g in ndone) ? ndone[g] : "-")
        n++
      }
      if (n == 0) print "surface\tempty\t-\t-\tno"
    }
  ' | LC_ALL=C sort
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Per-PR analysis
# ════════════════════════════════════════════════════════════════════════════════════════════════
RESULT=""
np_fail=0
np_incon=0

emit() { # emit <check> <verdict> <detail>
  RESULT="${RESULT}${1}	${2}	${3}
"
  case "$2" in
    FAIL) np_fail=$((np_fail + 1)) ;;
    INCONCLUSIVE) np_incon=$((np_incon + 1)) ;;
  esac
}

tree_of() { # tree_of <commit tsv>
  [ -s "$1" ] || return 0
  awk -F'\t' 'NR == 1 { print $2 }' "$1" 2>/dev/null
}

# ── 6 rail_landed — artifact-only; an override is a FAIL for this condition ──────────────────────
# Extracted from `analyse` so the UNREAD-record path can report it too: the route is answerable from
# this box's own artifacts even when GitHub could not be read, and the early return used to drop the
# row, leaving a 5-row report against the 6-row shape every other path emits (review round 3, note 2).
#
# ⛔ A NON-EMPTY `rail.out` IS NOT A LANDING (fresh-context review, round 6 — BLOCKING, a false PASS,
# and the only predicate here that was decided on FILE PRESENCE rather than on a fact). `rail.out` is
# `auto-<owner>-<repo>-<pr>.out`, the per-attempt verdict scratch file the rail's launcher writes
# (`auto-rail.sh:1705`, `:617` — the child's whole stdout+stderr), and the rail itself parses
# REFUSALS out of that same file (`cooldown_for`, `auto-rail.sh:569-575`). So the file's presence
# records "the rail was asked", never "the rail merged": a DENIED/DRAFT/CONFLICTED refusal, or the
# `ALREADY MERGED … no merge attempt` no-op, leaves a non-empty file too. Worse, because this arm was
# tested BEFORE the chain arm, ANY earlier rail attempt masked the one decisive FAIL this predicate
# can emit — a refused-then-chain-landed PR closed the capstone on exit 0.
#
# The fix is the SAME ALLOW-LIST POLARITY this file applies to check conclusions, on the rail's own
# words: the rail prints `admin-merge: ✅ merged PR #<PR> at <sha> (state=… confirmed via the API)` on
# a real landing (`admin-merge.sh:12399`/`:12402`) and nothing of the sort on a refusal (`:10035`
# prints `✅ PR #N is ALREADY MERGED … no merge attempt`, which this pattern deliberately does NOT
# match: it requires `merged PR #N`). An unrecognised artifact is UNKNOWN, never a landing.
#
# NO mtime WINDOW IS APPLIED TO `rail.out`, unlike the chain markers (F4), and the reason is
# structural rather than an omission: this artifact is fetched as
# `auto-<owner>-<repo>-<pr>.out` — repo-scoped AND PR-scoped by its NAME — and ONE attempt's words
# only (its launcher TRUNCATES it before every launch: `auto-rail.sh:928`, `: > "$out"` then `>>`),
# and a PR lands at most once, so no other repo's merge and no other landing of this number can
# produce it. The chain markers carry none of that and therefore DO need the window.
#
# ⛔ AND `merge.log` / `chain.verdict` ARE NOT LANDING SOURCES EITHER (fresh-context review, round 7 —
# BLOCKING: round 6 closed the `rail.out`-PRESENCE form and left the same false PASS open one layer
# down, through CONTENT). This loop used to search all three artifacts for the landing LINE, and
# `merge.log` is the per-PR CHAIN's own log: `merge-one.sh:122` sets `L="$O/logs/merge-$PR"` and
# `merge-one.sh:1119-1123` runs the rail as `bash "$RAIL" "$PR" … >> "$L.log" 2>&1`, so the rail's
# own `admin-merge: ✅ merged PR #N` line is written verbatim into the chain's log. Every CHAIN landing
# therefore set `landed_file=merge.log`, took the PASS arm below, and left the chain FAIL UNREACHABLE
# for the exact shape it exists for — the route reported as `auto-rail` on a landing the chain
# performed, on the predicate whose exit 0 closes the capstone. `merge.log` carries no scope of its
# own either: it is keyed by PR NUMBER ONLY (`lane-merge.sh:855`), so within the window another
# repo's PR of the same number can supply a landing line (the hazard F4 closes for `merged-<PR>.done`).
# So the rule is the SCOPE rule, not a text rule: `rail.out` is the only artifact that proves an
# AUTO-RAIL landing, and a landing line in the chain's own artifacts proves the CHAIN route.
emit_rail_landed() { # emit_rail_landed <dir> <pr> <mergedAt>
  local dir="$1" pr="$2" merged="$3"
  local landed_file="" chain_landing="" override_on_landing="" override_file="" saw_railout="" f
  for f in "$dir/rail.out" "$dir/merge.log" "$dir/chain.verdict"; do
    [ -s "$f" ] || continue
    [ "$f" = "$dir/rail.out" ] && saw_railout=1
    if grep -qE 'admin_merge_override|AGENT_ADMIN_MERGE_OVERRIDE' "$f" 2>/dev/null; then
      override_file="${f##*/}"
    fi
    # the rail's own success line, and it must name THIS PR — `([^0-9]|$)` so `#123` cannot match
    # `#1234`. Everything else (a refusal, a DRAFT/CONFLICTED/DENIED block, an ALREADY-MERGED no-op,
    # a bash start-failure written into the same file) is not a landing.
    grep -qE "admin-merge: .*merged PR #${pr}([^0-9]|$)" "$f" 2>/dev/null || continue
    if [ "$f" = "$dir/rail.out" ]; then
      landed_file="${f##*/}"
      # ⛔ THE OVERRIDE IS SCOPED TO THE LANDING'S OWN ATTEMPT, and `rail.out` is that attempt by
      # construction (truncated before every launch), so an override spelling in it IS on this
      # landing. The chain artifacts are append-only ACROSS attempts and across heads —
      # `merge-one.sh:1101-1105` records exactly this rule four lines above the redirect — so a PR
      # refused once (a refusal that NAMES the audited route, `admin-merge.sh:11622`), fixed, and
      # later landed normally would otherwise be reported as a certificate bypass: a false accusation
      # and a false FAIL on a landing that took the ordinary route (the #3996 class).
      grep -qE 'admin_merge_override|AGENT_ADMIN_MERGE_OVERRIDE' "$f" 2>/dev/null && override_on_landing="${f##*/}"
    else
      chain_landing="${f##*/}"
    fi
  done
  # ⛔ TWO FACTS, BOTH MEASURED (round 6, second direction of the same evidence model): the round-6
  # shape read a REFUSAL that merely NAMES the override route as an override landing. What the
  # predicate needs is a landing that HAPPENED and an override recorded ON IT.
  #
  # ORDER: a `rail.out` landing is preferred over a chain landing line, and that is not a loophole.
  # A PR lands at most once, so the two cannot both be true of the SAME landing: when the auto-rail
  # merged, a later chain run of the rail reads `ALREADY MERGED` and writes NO landing line. The only
  # way both appear is a foreign repo's same-numbered landing line in the number-keyed `merge.log`,
  # and then `rail.out` — repo- AND PR-scoped by its name — is the one that is about THIS PR.
  if [ -n "$landed_file" ] && [ -n "$override_on_landing" ]; then
    emit rail_landed FAIL "the rail records a LANDING of #$pr ($landed_file) together with an admin-merge override spelling in the same attempt — condition 6 forbids a landing that bypassed the certificate"
  elif [ -n "$landed_file" ]; then
    emit rail_landed PASS "the rail's own landing line names #$pr ($landed_file) and no override is recorded on it — the rail landed this PR on its own (admin-merge.sh:12399/12402)"
  elif [ -n "$chain_landing" ]; then
    emit rail_landed FAIL "landed by the per-PR chain, not by auto-rail — the landing line for #$pr is in $chain_landing, which is the chain's own artifact, and the auto-rail's per-attempt scratch file (rail.out) records no landing of it; capstone condition 6 requires the rail to land it on its own"
  elif [ -f "$dir/chain.merged" ] || [ -s "$dir/chain.verdict" ]; then
    emit rail_landed FAIL "landed by the per-PR chain, not by auto-rail — capstone condition 6 requires the rail to land it on its own"
  elif [ -f "$dir/chain.merged.out-of-window" ] || [ -f "$dir/chain.verdict.out-of-window" ] || [ -f "$dir/merge.log.out-of-window" ]; then
    # ⛔ THE MARKER EXISTED AND WAS REFUSED (F4). `$O/state` is shared by every repo on this box and
    # `merged-<PR>.done` carries no repo, so a `tortoise#<same n>` merge would otherwise be attributed
    # to THIS PR's landing. Outside this PR's own merge window it is not evidence — say so, and keep
    # the route unknown rather than guessing.
    emit rail_landed INCONCLUSIVE "a PR-number-keyed chain marker exists but is OUTSIDE this PR's merge window (mergedAt=$merged, window ${CHAIN_MARKER_WINDOW}s) — it is not proof for this repo's landing (chain-merge.sh:246-251 records the same rule), so the route stays unknown"
  elif [ -f "$dir/chain.merged.unusable" ] || [ -f "$dir/chain.verdict.unusable" ] || [ -f "$dir/merge.log.unusable" ]; then
    # ⛔ AN UNUSABLE WINDOW IS NOT AN OPEN ONE: `mergedAt` could not be parsed, so the marker can be
    # neither admitted nor shown to be OURS. Unknown, by construction.
    emit rail_landed INCONCLUSIVE "a PR-number-keyed chain marker exists but mergedAt='$merged' could not be parsed into a usable timestamp — an unusable window is never 'in window' (that would admit another repo's landing), so the route stays unknown"
  elif [ -n "$saw_railout" ]; then
    # the file is on disk and records NO landing of this PR: a refusal, a no-op, or an attempt that did
    # not merge. That is an unknown route, not a landing and not an override.
    emit rail_landed INCONCLUSIVE "the rail's output for this PR is on disk (rail.out) but it records NO landing of #$pr — a refusal, an ALREADY-MERGED no-op, or an attempt that did not merge$( [ -n "$override_file" ] && printf ' (it NAMES the override route, which a refusal does: that is not an override landing)') is not evidence of who landed it, so the route stays unknown"
  else
    emit rail_landed INCONCLUSIVE "no rail or chain artifact for this PR on this box — the landing route is not readable here"
  fi
  return 0
}

analyse() { # analyse <dir> <pr>
  local dir="$1" pr="$2" state merged merge_sha landed_tree
  state="$(awk -F'\t' 'NR == 1 { print $2 }' "$dir/pr.meta" 2>/dev/null)"
  merged="$(awk -F'\t' 'NR == 1 { print $3 }' "$dir/pr.meta" 2>/dev/null)"
  merge_sha="$(awk -F'\t' 'NR == 1 { print $4 }' "$dir/pr.meta" 2>/dev/null)"

  # ── 1 merged ──────────────────────────────────────────────────────────────────────────────────
  if [ -z "$state" ]; then
    emit merged INCONCLUSIVE "pr.meta is unreadable or absent — the PR's state was never read"
    return 0
  fi
  if [ "$state" != "MERGED" ] || [ -z "$merged" ] || [ "$merged" = "-" ]; then
    emit merged FAIL "PR #$pr state=$state mergedAt=${merged:--} — there is no landing to verify"
    return 0
  fi
  landed_tree="$(tree_of "$dir/commit-${merge_sha}.tsv")"
  if [ -z "$landed_tree" ]; then
    emit merged INCONCLUSIVE "PR is MERGED (mergedAt=$merged) but merge commit ${merge_sha:0:12} was not read — the landing is not readable"
    return 0
  fi
  emit merged PASS "mergedAt=$merged merge=${merge_sha:0:12} landed_tree=${landed_tree:0:12}"

  # ── 2 review_record ──────────────────────────────────────────────────────────────────────────
  # ⛔ AN UNREAD RECORD CHANNEL IS NOT AN ABSENT ONE (fresh-context review, round 2 F3). The body is
  # the recorder's CURRENT word and a comment is the weaker source, so reading through a failed `pr
  # view --json body` promotes an older comment marker to "this PR's current record" and deletes the
  # `not-clean` history `fix_round` needs — a fail-open on the two predicates the capstone is closed
  # on. The sentinel `store_read` writes is therefore CONSULTED here; without this, the sentinel was
  # an inert guard, which is worse than no guard because the comment claimed protection it gave none.
  local rc_unread=""
  for _rs in body.txt comments.txt; do
    [ -f "$dir/${_rs}.unread" ] && rc_unread="${rc_unread}${rc_unread:+,}${_rs}"
  done
  if [ -n "$rc_unread" ]; then
    emit review_record INCONCLUSIVE "the record channel(s) ${rc_unread} were NOT READ (gh refused / rate-limited) — the reviewed head of this PR is unknown here, and an unread body must not fall through to a weaker source"
    emit review_bound INCONCLUSIVE "no read review record to bind to the PR's final commit"
    emit fix_round INCONCLUSIVE "the record history was not read (${rc_unread}) — a fix round cannot be read from a channel nobody could open"
    emit green_gated INCONCLUSIVE "no reviewed head, so no head to read a check surface at"
    # `rail_landed` is answerable from this box's own artifacts, so it is reported here too — the early
    # return used to drop it, leaving a 5-row report against the 6-row shape every other path emits.
    emit_rail_landed "$dir" "$pr" "$merged"
    return 0
  fi

  # ⛔ THE SOURCE IS PART OF THE VERDICT, NOT A FOOTNOTE (review finding F3). A body marker is the
  # recorder's current word; a comment-only marker is a WEAKER source the recorder itself does not
  # accept as an artifact, and a box-local record file is weaker still (it is not in the PR). Every
  # one of those prints its own `source=` so a reader cannot mistake the strength of the evidence.
  local marker rverdict rsha rsource="marker-body" rsig="" rskipped rdenied rrefused="" rnotwhole
  marker="$(last_marker "$dir" "$pr")"
  rverdict="$(printf '%s' "$marker" | cut -f1)"
  rsha="$(printf '%s' "$marker" | cut -f2)"
  rsource="marker-$(printf '%s' "$marker" | cut -f3)"
  rsig="$(printf '%s' "$marker" | cut -f4)"
  rskipped="$(skipped_markers "$dir" "$pr")"
  rdenied="$(denied_markers "$dir" "$pr")"
  rnotwhole="$(nonwhole_markers "$dir" "$pr")"
  # ⛔ THE BOX-LOCAL RECORD FILE IS EVIDENCE ONLY WHEN ITS OWN `sig=` VERIFIES (fresh-context review,
  # round 8 — the same admission, second channel). It is weaker than a marker in the PR (nobody can
  # audit it: no comment, no body line), and the gate refuses an unauthenticated one outright
  # (`review_record_eval`: no `sig` field / a non-hex `sig` / no key on the box / a `sig` that does not
  # verify are all NON-evidence, #1224 finding 3). This reader used to read it on trust, so a
  # hand-written file at the store path satisfied `review_record` AND `review_bound` — an unauthenticated
  # artifact deciding the predicate the capstone closes on. Refusal is REPORTED (`rrefused`), never silent.
  if [ -z "$rsha" ] && [ -s "$dir/record.json" ]; then
    local recpr recsig recsig_text recok=""
    rverdict="$(sed -nE 's/.*"verdict"[[:space:]]*:[[:space:]]*"([a-z-]+)".*/\1/p' "$dir/record.json" | head -1)"
    rsha="$(sed -nE 's/.*"head_sha"[[:space:]]*:[[:space:]]*"([0-9a-f]{40})".*/\1/p' "$dir/record.json" | head -1)"
    rsource="record-file(weaker: not in the PR)"
    recpr="$(sed -nE 's/.*"pr"[[:space:]]*:[[:space:]]*([0-9]+).*/\1/p' "$dir/record.json" | head -1)"
    recsig="$(sed -nE 's/.*"sig"[[:space:]]*:[[:space:]]*"([0-9a-f]{64})".*/\1/p' "$dir/record.json" | head -1)"
    if [ -z "$recsig" ]; then
      rrefused="the box-local record file at head ${rsha:0:12} carries NO sig= field, so nothing binds its content to the review gate (the gate refuses exactly this)"
    elif [ -z "$GATE_KEY" ]; then
      rrefused="the box-local record file at head ${rsha:0:12} carries a sig= that cannot be VERIFIED — no AI_REVIEW_GATE_KEY in the environment or at ~/.pi/agent/.ai-review-gate-key on this box"
    elif [ -z "$recpr" ]; then
      rrefused="the box-local record file carries no pr field, so it attests no revision"
    elif [ "$recpr" != "$pr" ]; then
      # ⛔ THE FILE MUST ATTEST *THIS* PR (fresh-context review, round 9 — P3, MEASURED). The `pr` field
      # was used ONLY inside the signed text, never compared with the PR being verified, so a record
      # legitimately signed for another PR in the same repo verified here whenever the head matched — and
      # one head can carry several PRs (a stack). The gate binds the file to the PR this way: its
      # `review_record_eval` signs with the CALLER's PR number and requires the stored `repo` to equal the
      # target repo. (`repo` needs no separate check: it is inside the same signed text, so a record
      # minted for another repo cannot verify under this one's `$REPO`.)
      rrefused="the box-local record file was minted for PR #${recpr}, not PR #${pr} — a signed record for another PR is not this PR's review (the gate signs the caller's own PR number)"
    else
      recsig_text="$(printf 'review-record:v1:%s:%s:%s:%s' "$recpr" "$rsha" "$rverdict" "$REPO")"
      [ "$(printf '%s' "$recsig_text" | command openssl dgst -sha256 -hmac "$GATE_KEY" 2>/dev/null \
        | command awk '{print $NF}' || true)" = "$recsig" ] && recok=1
      [ -n "$recok" ] || rrefused="the box-local record file sig= does not verify under this box gate key — written under another key, edited after minting, or minted for a different revision"
    fi
    if [ -n "$recok" ]; then
      rsource="record-file(sig verified)"
    else
      rsha=""; rverdict=""
    fi
  fi

  if [ -z "$rsha" ]; then
    emit review_record INCONCLUSIVE "no ADMITTED review record for this PR at $REPO${rskipped:+ · refused as naming another repo: $rskipped}${rdenied:+ · refused by ADMISSION: $rdenied}${rnotwhole:+ · refused as NOT the whole artifact on channel(s) '$rnotwhole': the required check matches the marker against the WHOLE line / whole comment body, so a marker inside a longer comment, a list item, or a line carrying trailing prose is not evidence}${rrefused:+ · $rrefused} — the reviewed head is unknown here (a marker that names another repo is not evidence: record-review.sh refuses it, PR numbers collide across repos; a comment from an unattested author or with an unverifiable sig is not evidence either: the gate refuses it)"
    emit review_bound INCONCLUSIVE "no reviewed head to bind to the landed tree"
    emit fix_round INCONCLUSIVE "no record history to read a fix round from"
    emit green_gated INCONCLUSIVE "no reviewed head, so no head to read a check surface at"
  else
    # ⛔ THE VERDICT'S POLARITY IS THE POINT OF THIS PREDICATE (round 4 F2 — a FALSE PASS, measured).
    # It used to PASS on ANY admitted marker, so a landing whose standing record was `not-clean` — the
    # reviewer REFUSED that revision — reported `VERDICT: ALL-MET`, exit 0, from an instrument whose
    # exit 0 means the capstone may close. "A record exists" and "that record is clean" are different
    # facts; this predicate is named for the second one. Polarity is an ALLOW-LIST, the same rule the
    # check surface uses: an unrecognised verdict is unknown, never clean.
    case "$rverdict" in
      clean|clean-micro|clean-low)
        emit review_record PASS "verdict=$rverdict head=${rsha:0:12} source=$rsource auth=$rsig${rskipped:+ · refused-as-foreign:$rskipped}${rdenied:+ · refused-by-admission:$rdenied}${rnotwhole:+ · refused-as-not-whole:$rnotwhole}" ;;
      not-clean)
        emit review_record FAIL "the standing record at head ${rsha:0:12} is NOT-CLEAN (source=$rsource) — a reviewer REFUSED this revision, so no clean review covers the content that landed${rskipped:+ · refused-as-foreign:$rskipped}" ;;
      "")
        emit review_record INCONCLUSIVE "a record marker was admitted but carried no verdict word (head ${rsha:0:12}, source=$rsource) — the verdict is unknown, which is never clean" ;;
      *)
        emit review_record INCONCLUSIVE "the admitted record's verdict is '$rverdict' (head ${rsha:0:12}) — not a verdict this tool knows (clean|clean-micro|clean-low|not-clean), so it is unknown, never clean" ;;
    esac

    # ── 3 review_bound — the reviewed head is the PR's FINAL commit (base-independent) ─────────
    # ⛔ NOT tree equality — see the header's measured counter-example (#3996).
    local last_commit after
    if [ ! -s "$dir/pr-commits.tsv" ]; then
      emit review_bound INCONCLUSIVE "the PR's commit list was not read — cannot tell whether code was pushed after the review"
    else
      last_commit="$(tail -1 "$dir/pr-commits.tsv")"
      if [ "$last_commit" = "$rsha" ]; then
        emit review_bound PASS "reviewed head ${rsha:0:12} IS the PR's final commit — nothing was pushed after the review"
      else
        after="$(awk -v r="$rsha" 'h { print substr($0,1,12) } $0 == r { h = 1 }' "$dir/pr-commits.tsv" | paste -sd ',' -)"
        if [ -n "$after" ] && [ "$last_commit" != "$rsha" ]; then
          emit review_bound FAIL "the reviewed head ${rsha:0:12} is NOT the PR's final commit (${last_commit:0:12}); commits pushed AFTER the review and never re-reviewed: ${after:-none-readable}"
        else
          emit review_bound FAIL "the reviewed head ${rsha:0:12} is not in the PR's commit list at all (final ${last_commit:0:12}) — the record attests a revision this PR never carried to its tip"
        fi
      fi
    fi

    # ── 4 fix_round — the round must have CONVERGED: a clean tier at a head LATER than the last ──
    # refusal, in the record's own history.
    # the PR's whole admitted record history, both channels, oldest first: this is HISTORY, so the
    # weaker channel is legitimate here even though it is not for the current verdict (F3).
    #
    # ⛔ THE ANCHOR IS the LAST `not-clean`, NOT THE FIRST (fresh-context review, round 8 — P2, a FALSE
    # FAIL measured by execution). The old reader took the FIRST not-clean and asked what came
    # immediately AFTER it, so the ordinary shape `not-clean@H1 → not-clean@H2 → clean@H3` — a fix that
    # needed two rounds and converged, the repo allows up to ten review cycles — reported
    # `FAIL fix_round "the round did not converge"` and exit 1 while the same report printed
    # `PASS review_record verdict=clean head=H3`. The false FAIL is the #3996 class the header says gets
    # an instrument ignored, on capstone condition 4, for the ordinary shape of a two-round PR. What the
    # condition asks is whether the PR's LAST refusal was answered by a clean record at a later head;
    # "a reviewer still refuses this PR" is only true when the NEWEST marker is still not-clean.
    local hist verdict_of lastnc
    hist="$(markers_from "$dir" "$pr" '*')"
    verdict_of=""
    lastnc="$(printf '%s\n' "$hist" | awk -F'\t' '
      # walk to the END: the anchor is the last refusal, and `bad` keeps that head for the differ test
      { if ($1 == "not-clean") { last = substr($2,1,12); bad = $2 } }
      END { if (last != "") print last }
    ')"
    if [ -z "$hist" ]; then
      emit fix_round INCONCLUSIVE "no admitted record history for this PR on this box — a fix round cannot be read from nothing"
    elif [ -z "$lastnc" ]; then
      emit fix_round N/A "no not-clean verdict in this PR's record history — no fix round was owed"
    else
      # two facts after the LAST refusal: is there a CLEAN tier at a different (later) head, and is the
      # NEWEST marker still a refusal?
      verdict_of="$(printf '%s\n' "$hist" | awk -F'\t' '
        { v[NR] = $1; s[NR] = $2 }
        END {
          last = 0
          for (i = 1; i <= NR; i++) if (v[i] == "not-clean") last = i
          bad = s[last]
          # later, not merely different: a clean marker AFTER the last refusal, at another head
          for (i = last + 1; i <= NR; i++)
            if ((v[i] == "clean" || v[i] == "clean-micro" || v[i] == "clean-low") && s[i] != bad) {
              printf "CLEAN\t%s@%s\n", v[i], substr(s[i],1,12); exit
            }
          printf "NEWEST\t%s\n", v[NR]
        }
      ')"
      case "$verdict_of" in
        CLEAN*)
          emit fix_round PASS "not-clean@$lastnc was superseded by $(printf '%s' "$verdict_of" | cut -f2) — the verdict triggered a clean re-record at a new head" ;;
        *$'\t'not-clean)
          # nothing but refusals followed the last refusal: the round genuinely did not converge
          emit fix_round FAIL "not-clean@$lastnc is the NEWEST record for this PR — the round did not converge: a reviewer still refuses this PR after the fix" ;;
        *)
          emit fix_round FAIL "not-clean@$lastnc was never superseded by a record at a different head — no fix round followed the verdict" ;;
      esac
    fi

    # ── 5 green_gated — the surface AS THE LANDING SAW IT ──────────────────────────────────────
    if [ -f "$dir/checkruns-${rsha}.tsv.unread" ] || [ -f "$dir/runs-${rsha}.tsv.unread" ]; then
      emit green_gated INCONCLUSIVE "the surface at ${rsha:0:12} was NOT READ (gh refused / rate-limited, sentinel on disk) — an unread surface is unknown and is never a pass or a FAIL"
    elif [ ! -f "$dir/checkruns-${rsha}.tsv" ]; then
      emit green_gated INCONCLUSIVE "check-runs at ${rsha:0:12} were not read (no snapshot file) — the gating surface is unknown"
    elif [ ! -s "$dir/checkruns-${rsha}.tsv" ]; then
      # the read SUCCEEDED and the head carried no check-run at all: that is a measured zero, not an
      # unknown. Nothing was attached, so nothing gated the landing.
      emit green_gated FAIL "NOTHING had attached a verdict to ${rsha:0:12} by mergedAt=$merged — the landing was not gated by a run at that head"
    else
      local surf reds novotes pendings ngrp nnov nvote
      surf="$(surface_verdicts "$dir" "$rsha" "$merged")"
      if [ -z "$surf" ]; then
        emit green_gated INCONCLUSIVE "the surface read produced no groups — an empty read is unknown, never green"
      else
        reds="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "red" { print $1 ":" $3 }' | paste -sd ',' -)"
        local waited later
        waited="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "waited" { print $1 }' | paste -sd ',' -)"
        later="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "later" { print $1 }' | paste -sd ',' -)"
        if [ -n "$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "empty" { print; exit }')" ]; then
          emit green_gated FAIL "NOTHING had attached a verdict to ${rsha:0:12} by mergedAt=$merged — the landing was not gated by a run at that head"
        elif [ -n "$reds" ]; then
          # ⛔ THE DETAIL NAMES THE FACT, NOT A VERDICT ABOUT THE RAIL. The rail CAN land past a red
          # through its main-comparison exemption (a failure already red on main is not this PR's
          # — #3756/#3469), so "a red was visible" is not by itself misconduct. What the CAPSTONE
          # requires is that THE GREEN GATED the landing, and a green that completed after
          # `mergedAt` did not gate anything — that is the sentence this line has to be able to say.
          local never late earlier
          never="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "red" && $4 == "never"   { print $1 }' | paste -sd ',' -)"
          late="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "red" && $4 == "late"    { print $1 }' | paste -sd ',' -)"
          earlier="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "red" && $4 == "earlier" { print $1 }' | paste -sd ',' -)"
          local why=""
          [ -n "$never" ] && why="NEVER GREEN on this head before the merge: $never"
          [ -n "$late" ] && why="${why}${why:+ · }a green exists but completed AFTER mergedAt, so it gated nothing here: $late"
          [ -n "$earlier" ] && why="${why}${why:+ · }a green DID complete before mergedAt but a NEWER attempt on the same job was RED, so the newest verdict at the merge was not a green: $earlier"
          emit green_gated FAIL "the newest verdict at mergedAt=$merged on ${rsha:0:12} was RED: $reds — the green did not gate this landing. ${why}. (The rail's main-comparison exemption is a likely reason a merge was still permitted; that is a legitimate rail path, but it is not a green.)"
        elif [ -n "$waited" ]; then
          # the check EXISTED when the merge happened and had not voted: the landing did not wait for it
          emit green_gated FAIL "the landing did not wait for: $waited — each of these existed at mergedAt=$merged and had NO verdict by then (either it had started and not finished, or it was queued with no start timestamp — the API does not distinguish them), so the green did not gate this landing"
        else
          local ngreen nnonred
          ngreen="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "green" { n++ } END { print n + 0 }')"
          nnonred="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "nonred" { n++ } END { print n + 0 }')"
          if [ "$ngreen" -eq 0 ]; then
            emit green_gated FAIL "no group was GREEN at mergedAt=$merged on ${rsha:0:12} ($nnonred non-red only) — no green gated this landing"
          else
            emit green_gated PASS "$ngreen group(s) GREEN at mergedAt=$merged on ${rsha:0:12} (newest attempt per app/workflow/job)${nnonred:+$([ "$nnonred" -gt 0 ] && printf ' · %s non-red' "$nnonred")}${later:+ · not part of this gate (no run existed by mergedAt): $later}"
          fi
        fi
      fi
    fi
  fi

  # ── 6 rail_landed — one decision, one place (the block above; a second copy is the drift shape) ──
  emit_rail_landed "$dir" "$pr" "$merged"
  return 0
}

# ════════════════════════════════════════════════════════════════════════════════════════════════
# Main
# ════════════════════════════════════════════════════════════════════════════════════════════════
# A snapshot directory may hold every PR, so `--from-snapshot DIR` with no PR argument verifies all of
# them. That is what makes a frozen evidence directory re-checkable later without touching GitHub —
# the rate limit is shared with 22 landers, so a verifier that re-reads live is a bad citizen.
if [ -z "${PRS// /}" ] && [ -n "$SNAPSHOT_IN" ]; then
  for d in "$SNAPSHOT_IN"/*; do
    [ -d "$d" ] || continue
    PRS="$PRS $(basename "$d" | sed -E 's/^pr-//')"
  done
fi
if [ -z "${PRS// /}" ] && [ -n "$ISSUE" ]; then
  # ⛔ THE SEARCH IS FUZZY, SO THE CLOSING KEYWORD IS RE-DECIDED HERE. `--search "Closes #N"`
  # returned two merged PRs for the same issue (measured: --issue 3995 -> #3900 and #3969), and
  # reporting a stranger's PR as the one that closed the issue is the false-PASS direction. The
  # keyword is matched ON ITS OWN LINE, the same position rule `pipeline-compliance` check (a) uses.
  PRS="$("$GH" pr list --repo "$REPO" --state merged --search "Closes #$ISSUE" --limit 10 --json number,body \
    --jq ".[] | select((.body // \"\") | test(\"(?im)^[[:space:]>*+-]*(closes|fixes|resolves)[[:space:]]+#$ISSUE([^0-9]|$)\")) | .number" \
    2>/dev/null | tr '\n' ' ')"
  if [ -z "${PRS// /}" ]; then
    printf 'verify-landing-chain: no merged PR found closing #%s in %s\n' "$ISSUE" "$REPO" >&2
    exit 2
  fi
fi
if [ -z "${PRS// /}" ]; then
  printf 'verify-landing-chain: no PR given (positional, --issue, or a snapshot directory)\n' >&2
  usage
fi

WORK=""
cleanup() {
  if [ -n "$WORK" ] && [ -z "$SNAPSHOT_OUT" ]; then rm -rf "$WORK"; fi
}
trap cleanup EXIT INT TERM

ALL_FAIL=0
ALL_INCON=0
PR_BLOCKS=""

for pr in $PRS; do
  dir=""
  RESULT=""
  np_fail=0; np_incon=0
  if [ -n "$SNAPSHOT_IN" ]; then
    if [ -d "$SNAPSHOT_IN/pr-$pr" ]; then dir="$SNAPSHOT_IN/pr-$pr"
    elif [ -d "$SNAPSHOT_IN/$pr" ]; then dir="$SNAPSHOT_IN/$pr"; fi
    if [ -z "$dir" ]; then
      emit merged INCONCLUSIVE "no snapshot directory for PR $pr under $SNAPSHOT_IN"
    fi
  else
    if [ -n "$SNAPSHOT_OUT" ]; then
      dir="$SNAPSHOT_OUT/pr-$pr"
    else
      [ -n "$WORK" ] || WORK="$(mktemp -d)"
      dir="$WORK/pr-$pr"
    fi
    mkdir -p "$dir" 2>/dev/null
    if ! fetch_one "$dir" "$pr"; then
      RESULT=""; np_fail=0; np_incon=0
      emit merged INCONCLUSIVE "gh could not read PR #$pr in $REPO — the verification did not run"
    fi
  fi

  if [ -n "$dir" ] && [ -z "$RESULT" ]; then
    # the head surface needs a second read keyed on the REVIEWED head, so it is fetched here and only
    # here — a predicate stays a pure function of the directory.
    rsha_pre="$(last_marker "$dir" "$pr" | cut -f2)"
    if [ -z "$rsha_pre" ] && [ -s "$dir/record.json" ]; then
      rsha_pre="$(sed -nE 's/.*"head_sha"[[:space:]]*:[[:space:]]*"([0-9a-f]{40})".*/\1/p' "$dir/record.json" | head -1)"
    fi
    if [ -z "$SNAPSHOT_IN" ] && [ -n "$rsha_pre" ] && [ ! -s "$dir/checkruns-${rsha_pre}.tsv" ]; then
      fetch_head_surface "$dir" "$rsha_pre" || true
    fi
    analyse "$dir" "$pr"
  fi

  ALL_FAIL=$((ALL_FAIL + np_fail))
  ALL_INCON=$((ALL_INCON + np_incon))
  PR_BLOCKS="${PR_BLOCKS}@@PR	${pr}
${RESULT}"
done

# ── report ──────────────────────────────────────────────────────────────────────────────────────
if [ "$JSON" -eq 1 ]; then
  printf '%s' "$PR_BLOCKS" | $VERIFY_AWK -F'\t' '
    # ⛔ A CHARACTER LOOP, NOT `gsub(/\\/,"\\\\",o)` (fresh-context review, round 7, P3). Escape
    # processing inside a gsub REPLACEMENT is not portable: measured on one input backslash, the
    # `"\\\\"` replacement yields TWO backslashes on gawk/mawk/nawk defaults but ONE under
    # `awk --posix` (i.e. a no-op, so a backslash in a detail emitted INVALID JSON — `\z` is not a
    # JSON escape), while the `"\\\\\\\\"` replacement yields two on gawk and FOUR on mawk. Building
    # the escape from concatenated SINGLE-CHARACTER literals removes the replacement rules entirely:
    # verified identical on gawk, mawk, nawk and `awk --posix`.
    # ⛔ AND A CONTROL BYTE IS ESCAPED TOO (fresh-context review, round 8, P3). `\\` and `"` alone left
    # every byte below 0x20 emitted RAW — `json.load` failed with `Invalid control character at char
    # 122` on a snapshot whose `mergedAt` carried one — so the evidence file was invalid JSON from a
    # hand-made or foreign snapshot (the same class the suite already accepted for backslash+quote, one
    # character set short). RFC 8259 §7 requires every character below 0x20 to be escaped; `\\u00XX`
    # is the portable spelling here because `\\b`/`\\f`/`\\n`/`\\r`/`\\t` short forms and octal escapes
    # vary across awks. Built from a one-character lookup table, so no numeric-to-string conversion and
    # no format trap: verified identical on gawk, mawk and `awk --posix`.
    function jstr(s,   o, i, c, h) {
      o = ""
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "\\")      o = o "\\" "\\"
        else if (c == "\"") o = o "\\" "\""
        else if (c in CTL)    o = o "\\u00" CTL[c]
        else                  o = o c
      }
      return "\"" o "\""
    }
    BEGIN {
      # 0x00-0x1f, one entry per byte, the code being the two hex digits JSON wants
      split("00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f 10 11 12 13 14 15 16 17 18 19 1a 1b 1c 1d 1e 1f", H, " ")
      for (i = 1; i < 32; i++) CTL[sprintf("%c", i)] = H[i + 1]
      printf "{\"prs\":["; firstpr = 1
    }
    $1 == "@@PR" { if (!firstpr) printf "]}"; printf "%s{\"pr\":%s,\"checks\":[", (firstpr ? "" : ","), $2; firstpr = 0; n = 0; next }
    NF >= 3 { if (n++) printf ","; printf "{\"check\":%s,\"verdict\":%s,\"detail\":%s}", jstr($1), jstr($2), jstr($3); next }
    END { if (!firstpr) printf "]}"; printf "]}\n" }
  '
else
  printf '%s' "$PR_BLOCKS" | while IFS="$(printf '\t')" read -r a b c; do
    if [ "$a" = "@@PR" ]; then
      printf '\nPR #%s  (%s)\n' "$b" "$REPO"
      continue
    fi
    case "$b" in
      PASS) mark="PASS " ;;
      FAIL) mark="FAIL " ;;
      N/A)  mark="n/a  " ;;
      *)    mark="INCON" ;;
    esac
    printf '  %s %-14s %s\n' "$mark" "$a" "$c"
  done
  printf '\n'
  if [ "$ALL_FAIL" -gt 0 ]; then
    printf 'VERDICT: NOT-ALL-MET — %s check(s) FAILED, %s INCONCLUSIVE\n' "$ALL_FAIL" "$ALL_INCON"
  elif [ "$ALL_INCON" -gt 0 ]; then
    printf 'VERDICT: INCOMPLETE — 0 FAILED, %s INCONCLUSIVE (an unread check is never a pass)\n' "$ALL_INCON"
  else
    printf 'VERDICT: ALL-MET — every check PASS or N/A\n'
  fi
fi

[ "$ALL_FAIL" -gt 0 ] && exit 1
[ "$ALL_INCON" -gt 0 ] && exit 2
exit 0
