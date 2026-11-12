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
#   review_record  a review record exists (the recorder's own marker, read from the PR body or its
#                  comments — durable and therefore CROSS-BOX; a local
#                  ~/.pi/agent/reviews/<owner>-<repo>-<pr>.json is a fallback only).
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
#   rail_landed    the rail landed it on its own, with no `admin_merge_override` anywhere on it
#                  (condition 6). Artifact-only: the rail's output file, the chain's own markers.
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
[ -f "$HERE/repo-slug.sh" ] && . "$HERE/repo-slug.sh" >/dev/null 2>&1
case "$REPO" in
  */*)
    # a box may pin REPO to a CHECKOUT (that form is supported and must not be mistaken for a slug);
    # anything that is not already a slug is derived through the same parser, never parsed here.
    if ! repo_slug_valid "$REPO" 2>/dev/null; then
      REPO="$(derive_or "$REPO" "" 2>/dev/null)" || REPO=""
    fi ;;
esac
if ! repo_slug_valid "$REPO" 2>/dev/null; then
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
iso_epoch() { # iso_epoch <2026-11-12T05:05:55Z> → seconds since epoch, or EMPTY
  local t="${1:-}"
  case "$t" in ""|-) return 1 ;; esac
  case "$t" in
    *Z) : ;;
    *) return 1 ;;
  esac
  date -u -d "$t" +%s 2>/dev/null || date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$t" +%s 2>/dev/null || printf ''
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
# comments.txt         comment bodies, in order, separated by a <<<COMMENT>>> line
# record.json          this box's record file, when one exists (fallback source)
# rail.out             the rail's output for this PR, when this box landed it
# chain.merged         the per-PR chain's `state/merged-<pr>.done` marker
# chain.verdict        lane-merge.sh's machine verdict for the PR
# merge.log            the per-PR chain's log
# commit-<sha>.tsv     <sha> TAB <tree> TAB <comma-separated parents>
# runs-<sha>.tsv       <run_id> TAB <workflow name> TAB <run_attempt>
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
  # markers ACCUMULATE in the comments across a fix round; that is where the round's history lives
  store_read "$dir" comments.txt \
    "$GH" pr view "$pr" --repo "$REPO" --json comments \
      --jq '.comments[] | "<<<COMMENT>>>\n" + (.body // "")'

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
  local mt mt_s mt_e
  mt="$(awk -F'\t' 'NR == 1 { print $3 }' "$dir/pr.meta" 2>/dev/null)"
  mt_s="$(iso_epoch "$mt")"
  if [ -n "$mt_s" ]; then
    mt_e=$((mt_s + CHAIN_MARKER_WINDOW))
    mt_s=$((mt_s - CHAIN_MARKER_WINDOW))
  fi
  chain_artifact() { # chain_artifact <path> <store-name>
    [ -f "$1" ] || return 1
    local f_ts f_s
    f_s=""
    if [ -n "${mt_s:-}" ]; then
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
store_read() { # store_read <dir> <name> <command…>  → 0 stored · 1 STORED but empty-ish · 2 UNREAD
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
      --jq '.workflow_runs[] | [.id, .name, .run_attempt] | @tsv' || rc_runs=$?
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
# statement (record-review.sh:4896-4899, "the poster APPENDS … keep the LAST"), while a marker found
# only in a COMMENT is a weaker source (record-review.sh:1092-1094 does not accept a comment marker as
# an artifact). `sig=` is recorded but NOT verified here, and every detail line says so.
record_markers() { # record_markers <dir> <pr>
  #   MARK <channel> <verdict> <sha> <repo> <sig?>   ·   SKIP <channel> <sha> <repo-or-(none)>
  local dir="$1" pr="$2"
  {
    # the BODY last, and tagged, so "the recorder's current word" is distinguishable from history
    [ -s "$dir/comments.txt" ] && sed 's/^/COMMENT\t/' "$dir/comments.txt"
    printf 'BODY\t\n'
    [ -s "$dir/body.txt" ] && sed 's/^/BODY\t/' "$dir/body.txt"
  } | awk -F'\t' -v pr="$pr" -v want="$REPO" '
    BEGIN { fold = tolower(want) }
    {
      chan = $1
      line = $0
      sub(/^[^\t]*\t/, "", line)
      sub(/^[[:space:]>*+\x2d]+/, "", line)
      # the recorder writes: review recorded: reviews/<pr>.json verdict=V @ <40hex> (owner/repo)
      if (index(line, "review recorded: reviews/" pr ".json verdict=") != 1) next
      rest = line
      sub(/^review recorded: reviews\/[^ ]* verdict=/, "", rest)
      v = rest; sub(/ .*$/, "", v)
      if (v != "clean" && v != "clean-micro" && v != "clean-low" && v != "not-clean") next
      if (rest !~ / @ [0-9a-f]+( |$)/) next
      s = rest; sub(/^.* @ /, "", s); sub(/ .*$/, "", s)
      if (length(s) != 40 || tolower(s) !~ /^[0-9a-f]+$/) next
      sig = (line ~ / sig=[0-9a-f]+$/) ? "sig" : "nosig"
      repo = ""
      # the FIRST parenthesised slug-shaped group is the marker repo; text after it (findings=, sig=)
      # cannot match, because a slug-shaped group has no spaces
      if (match(line, /\([A-Za-z0-9._-]+\/[A-Za-z0-9._-]+\)/)) {
        repo = substr(line, RSTART + 1, RLENGTH - 2)
      }
      if (repo == "")            { printf "SKIP\t%s\t%s\t(none)\n", chan, substr(s, 1, 12); next }
      if (tolower(repo) != fold) { printf "SKIP\t%s\t%s\t%s\n",     chan, substr(s, 1, 12), repo; next }
      printf "MARK\t%s\t%s\t%s\t%s\t%s\n", chan, v, s, repo, sig
    }
  '
}

# this repo, one channel: "verdict TAB sha TAB sig", oldest first
markers_from() {
  record_markers "$1" "$2" | awk -F'\t' -v ch="$3" \
    '$1 == "MARK" && (ch == "*" || $2 == ch) { print $3 "\t" $4 "\t" $6 }'
}

# the recorder's CURRENT word is the body; a comment-only marker is a declared weaker source
last_marker() { # → "verdict TAB sha TAB source TAB sig"; empty when nothing admitted
  local dir="$1" pr="$2" v s sig
  v="$(markers_from "$dir" "$pr" BODY | tail -1)"
  if [ -n "$v" ]; then
    printf '%s\t%s\tbody\t%s\n' "$(printf '%s' "$v" | cut -f1)" "$(printf '%s' "$v" | cut -f2)" "$(printf '%s' "$v" | cut -f3)"
    return 0
  fi
  v="$(markers_from "$dir" "$pr" COMMENT | tail -1)"
  [ -n "$v" ] || return 1
  printf '%s\t%s\tcomment\t%s\n' "$(printf '%s' "$v" | cut -f1)" "$(printf '%s' "$v" | cut -f2)" "$(printf '%s' "$v" | cut -f3)"
}

skipped_markers() { # → "channel:sha:repo" for the markers refused as foreign, or empty
  record_markers "$1" "$2" | awk -F'\t' '$1 == "SKIP" { print $2 ":" $3 ":" $4 }' | paste -sd ',' -
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
    sect == "runs" && NF >= 2 { wf[$1] = $2; next }
    sect == "checks" && NF >= 7 {
      id = $1 + 0; app = $2; name = $3; status = $4; conc = $5; done_at = $6; url = $7; started_at = $8
      rid = runid_of(url); w = (rid != "" ? wf[rid] : "")
      if (w == "") w = "app:" app
      g = w "/" name
      seen[g] = 1
      if (!(g in atid) || id > atid[g]) {
        # only an attempt that had a VERDICT at or before the merge counts as what the landing saw
        if (status == "completed" && done_at != "-" && done_at != "" && done_at <= merged) {
          atid[g] = id; atcls[g] = classify(status, conc); atconc[g] = conc; atdone[g] = done_at
        }
      }
      if (classify(status, conc) == "green") evergreen[g] = 1
      # did this group have an attempt IN FLIGHT when the landing happened?
      if (started_at != "-" && started_at != "" && started_at <= merged) started[g] = 1
      next
    }
    END {
      n = 0
      for (g in seen) {
        # ⛔ THREE STATES, NOT TWO (review finding F1). A group with no verdict at `mergedAt` is either
        #   waited  — at least one attempt had STARTED by then (the landing went ahead without it), or
        #   later   — no attempt existed yet (a post-merge job; it was never part of this gate).
        # Collapsing both into one "novote" is what let one green group and two in-flight groups read
        # as "3 group(s) green", which is false in the direction the capstone is closed on.
        if (g in atcls)            v = atcls[g]
        else if (g in started)     v = "waited"
        else                       v = "later"
        print g "\t" v "\t" ((g in atconc) ? atconc[g] : "-") "\t" ((g in atdone) ? atdone[g] : "-") "\t" ((g in evergreen) ? "yes" : "no")
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
  # ⛔ THE SOURCE IS PART OF THE VERDICT, NOT A FOOTNOTE (review finding F3). A body marker is the
  # recorder's current word; a comment-only marker is a WEAKER source the recorder itself does not
  # accept as an artifact, and a box-local record file is weaker still (it is not in the PR). Every
  # one of those prints its own `source=` so a reader cannot mistake the strength of the evidence.
  local marker rverdict rsha rsource="marker-body" rsig="" rskipped
  marker="$(last_marker "$dir" "$pr")"
  rverdict="$(printf '%s' "$marker" | cut -f1)"
  rsha="$(printf '%s' "$marker" | cut -f2)"
  rsource="marker-$(printf '%s' "$marker" | cut -f3)"
  rsig="$(printf '%s' "$marker" | cut -f4)"
  rskipped="$(skipped_markers "$dir" "$pr")"
  if [ -z "$rsha" ] && [ -s "$dir/record.json" ]; then
    rverdict="$(sed -nE 's/.*"verdict"[[:space:]]*:[[:space:]]*"([a-z-]+)".*/\1/p' "$dir/record.json" | head -1)"
    rsha="$(sed -nE 's/.*"head_sha"[[:space:]]*:[[:space:]]*"([0-9a-f]{40})".*/\1/p' "$dir/record.json" | head -1)"
    rsource="record-file(weaker: not in the PR)"
  fi

  if [ -z "$rsha" ]; then
    emit review_record INCONCLUSIVE "no ADMITTED review record for this PR at $REPO${rskipped:+ · refused as naming another repo: $rskipped}${rskipped:- } — the reviewed head is unknown here (a marker that names another repo is not evidence: record-review.sh refuses it, PR numbers collide across repos)"
    emit review_bound INCONCLUSIVE "no reviewed head to bind to the landed tree"
    emit fix_round INCONCLUSIVE "no record history to read a fix round from"
    emit green_gated INCONCLUSIVE "no reviewed head, so no head to read a check surface at"
  else
    emit review_record PASS "verdict=$rverdict head=${rsha:0:12} source=$rsource sig=$([ "$rsig" = sig ] && echo unverified || echo absent)${rskipped:+ · refused-as-foreign:$rskipped}"

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

    # ── 4 fix_round — a not-clean must be superseded at a DIFFERENT head, LATER in the record ──
    # the PR's whole admitted record history, both channels, oldest first: this is HISTORY, so the
    # weaker channel is legitimate here even though it is not for the current verdict (F3).
    local hist superseded firstnc
    hist="$(markers_from "$dir" "$pr" '*')"
    firstnc="$(printf '%s\n' "$hist" | awk -F'\t' '$1 == "not-clean" { print substr($2,1,12); exit }')"
    if [ -z "$hist" ]; then
      emit fix_round INCONCLUSIVE "no admitted record history for this PR on this box — a fix round cannot be read from nothing"
    elif [ -z "$firstnc" ]; then
      emit fix_round N/A "no not-clean verdict in this PR's record history — no fix round was owed"
    else
      # the FIRST later marker whose head differs from the not-clean one — later, not merely different
      superseded="$(printf '%s\n' "$hist" | awk -F'\t' '
        { if (found) { if ($2 != bad) { print $1 "@" substr($2,1,12); exit } } else if ($1 == "not-clean") { found = 1; bad = $2 } }
      ')"
      if [ -n "$superseded" ]; then
        emit fix_round PASS "not-clean@$firstnc was superseded by $superseded — the verdict triggered a re-record at a new head"
      else
        emit fix_round FAIL "not-clean@$firstnc was never superseded by a record at a different head — no fix round followed the verdict"
      fi
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
          local never late
          never="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "red" && $5 == "no" { print $1 }' | paste -sd ',' -)"
          late="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "red" && $5 == "yes" { print $1 }' | paste -sd ',' -)"
          local why=""
          [ -n "$never" ] && why="NEVER GREEN on this head before the merge: $never"
          [ -n "$late" ] && why="${why}${why:+ · }green exists but completed AFTER mergedAt (so it gated nothing here): $late"
          emit green_gated FAIL "the newest verdict at mergedAt=$merged on ${rsha:0:12} was RED: $reds — the green did not gate this landing. ${why}. (The rail's main-comparison exemption is a likely reason a merge was still permitted; that is a legitimate rail path, but it is not a green.)"
        elif [ -n "$waited" ]; then
          # the check EXISTED when the merge happened and had not voted: the landing did not wait for it
          emit green_gated FAIL "the landing did not wait for: $waited — these had started by mergedAt=$merged and had no verdict, so the green did not gate this landing"
        else
          local ngreen nnonred
          ngreen="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "green" { n++ } END { print n + 0 }')"
          nnonred="$(printf '%s\n' "$surf" | awk -F'\t' '$2 == "nonred" { n++ } END { print n + 0 }')"
          if [ "$ngreen" -eq 0 ]; then
            emit green_gated FAIL "no group was GREEN at mergedAt=$merged on ${rsha:0:12} ($nnonred non-red only) — no green gated this landing"
          else
            emit green_gated PASS "$ngreen group(s) GREEN at mergedAt=$merged on ${rsha:0:12} (newest attempt per app/workflow/job)${nnonred:+ · $nnonred non-red}${later:+ · not part of this gate (no run existed by mergedAt): $later}"
          fi
        fi
      fi
    fi
  fi

  # ── 6 rail_landed — artifact-only; an override is a FAIL for this condition ──────────────────
  local override_found="" f
  for f in "$dir/rail.out" "$dir/merge.log" "$dir/chain.verdict"; do
    [ -s "$f" ] || continue
    if grep -qE 'admin_merge_override|AGENT_ADMIN_MERGE_OVERRIDE' "$f" 2>/dev/null; then
      override_found="${f##*/}"
    fi
  done
  if [ -n "$override_found" ]; then
    emit rail_landed FAIL "an admin-merge override is recorded ($override_found) — condition 6 forbids a landing that bypassed the certificate"
  elif [ -s "$dir/rail.out" ]; then
    emit rail_landed PASS "the rail's own output for this PR is on disk (rail.out) and carries no override"
  elif [ -f "$dir/chain.merged" ] || [ -s "$dir/chain.verdict" ]; then
    emit rail_landed FAIL "landed by the per-PR chain, not by auto-rail — capstone condition 6 requires the rail to land it on its own"
  elif [ -f "$dir/chain.merged.out-of-window" ] || [ -f "$dir/chain.verdict.out-of-window" ] || [ -f "$dir/merge.log.out-of-window" ]; then
    # ⛔ THE MARKER EXISTED AND WAS REFUSED (F4). `$O/state` is shared by every repo on this box and
    # `merged-<PR>.done` carries no repo, so a `tortoise#<same n>` merge would otherwise be attributed
    # to THIS PR's landing. Outside this PR's own merge window it is not evidence — say so, and keep
    # the route unknown rather than guessing.
    emit rail_landed INCONCLUSIVE "a PR-number-keyed chain marker exists but is OUTSIDE this PR's merge window (mergedAt=$merged, window ${CHAIN_MARKER_WINDOW}s) — it is not proof for this repo's landing (chain-merge.sh:246-251 records the same rule), so the route stays unknown"
  else
    emit rail_landed INCONCLUSIVE "no rail or chain artifact for this PR on this box — the landing route is not readable here"
  fi
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
  printf '%s' "$PR_BLOCKS" | awk -F'\t' '
    function jstr(s,  o) { o = s; gsub(/\\/, "\\\\", o); gsub(/"/, "\\\"", o); return "\"" o "\"" }
    BEGIN { printf "{\"prs\":["; firstpr = 1 }
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
