#!/usr/bin/env bash
# record-review.sh <pr> <head_sha> [verdict] [repo] [--evidence <artifact>]
# Records a code-review verdict for a PR into ~/.pi/agent/reviews/<PR>.json,
# consumed by the review-enforcer merge registry gate
# (extensions/review-enforcer/index.ts, issue #138).
#
# Canonical copy — production lives at ~/.pi/agent/scripts/record-review.sh,
# refreshed from this repo copy by the pi-bootstrap/setup.sh merge-gate
# scripts farm (#562) on every sync (auto-sync at session_start / sync.sh).
# Edit THIS file; do NOT hand-edit the ~/.pi copy — setup.sh re-copies it.
# The repo copy is what CI tests (ci-main.yml script-validate).
#
# <repo> is optional (owner/name). When omitted it is auto-detected via
# GH_REPO env or `gh repo view` when run inside a git repo. The merge gate
# uses the repo field to verify PRs in ANY repo, not just the pi process cwd.
#
# --force-stale (any position): record a head_sha that is NOT the PR's
# current head. Off by default — the stale-sha guard (#2133) refuses such
# records with exit 3 because the ai-review-gate rejects them anyway.
#
# --evidence <artifact> — REQUIRED to mint a `clean` record (issue tortoise#7391).
# Names the review artifact this verdict rests on, one of:
#   comment:<id>            a PR issue comment        (this fleet's convention)
#   review:<id>             a PR review
#   review-comment:<id>     an inline review comment
#   <a GitHub URL>          any of the three, pasted (…/pull/N#issuecomment-ID,
#                           #discussion_rID, #pullrequestreview-ID)
# The script then VERIFIES it: it must exist, belong to THIS PR, POSTDATE the
# recorded head's commit, and NOT assert an UNRESOLVED outcome — NOT-CLEAN, or
# the review skills' own exit markers ("Auto-fix stalled/failed/reached … cap",
# "N issues remain", "requires human attention/input"). Anything it
# cannot verify — including an unreachable API — REFUSES (exit 3). Until
# tortoise#7391 this script asked that question on NO path: passing the PR's current
# head recorded unconditionally, so the most natural invocation there is
# ("record this PR at its current head") minted a validly-signed, head-bound
# `verdict=clean` with no review behind it. tortoise#3549 merged on exactly
# such a record (every review artifact on that PR said NOT CLEAN).
#
# WHAT THE CHECK IS AND IS NOT. It makes an unfounded record require a PUBLIC,
# NAMED, TIMESTAMPED claim, and stores that claim in the record so it is
# auditable afterwards. It does NOT make forgery impossible, and it does NOT
# check that the artifact it accepts IS a review: it verifies existence, PR
# membership, age and the absence of an UNRESOLVED assertion, so a bot or CI
# comment that describes no review satisfies it as well. The recording lane can
# therefore author the comment it names, or name one that is no review at all.
#
# The age test is ONE-DIRECTIONAL and this is a declared residual, not an
# oversight: `created_at >= head_commit_date` proves the artifact postdates the
# recorded revision, but NOT that the artifact reviewed THAT revision. After a
# force-push BACKWARD onto an older commit, a genuine clean review of the newer
# head still postdates the older one and is therefore accepted at it. Closing it
# needs the PR's force-push/pushed_at timeline (or a content binding, which the
# carry path deliberately does not do — recorded decision #1362 D1), so it is a
# named gap: a consumer-side content binding is the successor, home agent-infra
# #1224.
# Neither is an accident — each takes an explicit argument — and closing them
# needs a reviewer identity boundary this fleet cannot supply (every session
# authenticates as the same GitHub account, and the reviewer is a sub-agent of
# the recording lane). It is an auditability and friction boundary, not a proof
# of review: what it removes is the SILENT path, where naming the PR's current
# head minted `clean` with no argument at all.
#
# A CARRY does not need --evidence. A carry is not a fresh attestation: the
# DIFF carry rides a prior signed marker it verified, and the record says so via
# `"mint":"carried"`. The LANE carry (a base-only move) verifies the git graph,
# not a record — its freshness argument is inherited from the pre-#7391 design
# and it is the one carry arm with no marker behind it; it is a named residual
# rather than a closed one, and tests/record-review/run.sh covers its predicate.
# clean-micro and clean-low are also not covered, and that is deliberate —
# clean-micro certifies the micro PROCESS (tier guard + pre-flight + the #485
# dispatch floor), which is a review-free attestation of a different kind, and
# clean-low's content-shape guard is fail-closed and re-reads the head itself.
# A `clean` record is the only one that claims a full review happened and cannot
# otherwise be verified.
#
# Mint provenance (tortoise#7391). Every record now carries `"mint":"fresh"|"carried"`.
# A carried record additionally carries `"carried_from":<prior head>` and
# `"carried_at"`, and its `reviewed_at` is the ORIGINAL mint time recovered
# from the record it superseded — not the carry time, which used to overwrite
# it and made the mint time unrecoverable after the fact. When the original
# cannot be recovered the script says so loudly on stderr and `mint` marks the
# record as carried, so `reviewed_at` is never silently a carry time.
#
# Verdicts (issue #513; clean-low added by #1348):
#   clean       — a code-review skill convergence recorded its clean verdict
#                 (standard/complex tiers). Never tier-guarded.
#   clean-micro — the micro-tier PROCESS verdict: micro skips the code-review
#                 skill, so its merge record certifies the micro flow
#                 (complexity:micro linked issue + pre-flight per risk tier +
#                 the #485 ≥1-dispatch floor), NOT a multi-agent review. The
#                 clean-micro tier guard below verifies the linked same-repo
#                 issue carries the complexity:micro label at record time and
#                 REFUSES (exit 4, no write) when any same-repo closing ref
#                 is a non-micro complexity:* issue. Clean verdicts make zero
#                 extra gh calls.
#   clean-low   — the Low code-impact class (the Low value of proportional-gates'
#                 §Change Classification `Code impact` column — NOT that file's
#                 §Review Cycles Low ROW, which has no file class at all): every
#                 changed path of the recorded revision
#                 is prose or a stylesheet (no program code, no config file, no
#                 enforcement input). The content shape is the whole VERIFIABLE
#                 attestation — the Low tier's single reviewer pass is the
#                 caller's obligation and nothing here can observe it. Because
#                 the shape is the whole attestation, the guard below is
#                 FAIL-CLOSED on every arm — "could not verify" must never read
#                 as "certified Low"
#                 (unlike clean-micro, whose fail-open arm is safe because the
#                 label only cross-checks a flow that already ran its own
#                 pre-flight and dispatch floor). NOTE the class is PATH +
#                 EXTENSION based and does NOT consult a build graph: a repo may
#                 consume a docs/** file as package data or a generated artifact
#                 (e.g. tortoise's pyproject.toml package-data). That is
#                 accepted and declared — the attestation is deliberately
#                 limited to a shape this guard can actually read. See the
#                 clean-low guard in main and the predicates below.
set -euo pipefail

# ── closing_issue_refs <text> ─────────────────────────────────────────────
# Print EVERY issue reference resolved by a closing keyword in <text>, one
# "owner/repo#num" per line, deduplicated. Mirrors check-pipeline-compliance.sh
# parse_issue_ref's accepted forms + per-ref form priority (a. full URL
# https://github.com/<o>/<r>/issues/<n> — never /pull/<n>; b. owner/repo#<n>;
# c. bare #<n> → repo = $REPO) but returns ALL refs — parse_issue_ref is
# first-ref-only, while the tier guard needs ANY-ref semantics (a PR closing
# two same-repo issues of different tiers has no single tier identity).
# Keyword class: fix(es|ed)?|close(s|d)?|resolve(s|d)? directly followed by
# the reference (so "resolves SLACK_APPROVAL_FILE" is not an issue ref), and
# sitting in a REFERENCE CONTEXT (REFCTX): the keyword begins a line, optionally
# after ONE OR MORE Markdown prefixes GitHub renders as line-leading reference
# markers (bullet / ordered marker / blockquote / ATX heading / task-list
# checkbox) or emphasis/bold/backtick marks. The prefix and checkbox groups are
# REPEATABLE, so a COMPOUND prefix is a reference context too — `> - Closes #42`
# and `> > Closes #42` auto-close on GitHub just like `- Closes #42`. A
# mid-sentence mention is NOT a reference (#1012) — position is the contract,
# matching check-pipeline-compliance.sh::parse_issue_ref, which composes the
# SAME two constants.
#
# The CROSS-SCRIPT INVARIANT is scoped to the keyword CLASS, not the position
# rule: REFCTX and CLOSING_KW are byte-identical across the two scripts, pinned
# mechanically by record-review.test.sh §8.13. The #513 tier guard below does
# NOT rely on the positional rule for GitHub parity — GitHub auto-closes a
# mid-sentence ref, so the guard ALSO scans with a WORD-BOUNDARY-ANCHORED
# CLOSING_KW (passing `\b${CLOSING_KW}` as closing_issue_refs' optional
# <kw-pattern>) and refuses when a non-micro ref appears in either scan. The
# `\b` is load-bearing in the FALSE-REFUSAL direction: the keyword class is a
# SUFFIX of ordinary English words ("prefix", "discloses", "unresolved"), so an
# unanchored scan reads `The prefix #42 is unrelated.` as `fix #42`, fetches
# #42's labels, and refuses a record GitHub would never auto-close — a false
# refusal, and strictly BROADER than GitHub, which requires a word boundary.
# Scoping the invariant to the class is what keeps the positional rule
# (check (a), anti-#968) from becoming a tier-guard fail-open.
# Top-level + guarded main below: this function is source-reachable by tests.
REFCTX='^[[:space:]]*(([-*+]|[0-9]+[.)])[[:space:]]+|#{1,6}[[:space:]]+|>[[:space:]]*)*(\[[ xX]\][[:space:]]+)*[*_`]{0,3}[[:space:]]*'
CLOSING_KW='(fix(es|ed)?|close(s|d)?|resolve(s|d)?)'
closing_issue_refs() {
  # <kw-pattern> (optional) selects the keyword class WITHOUT the positional
  # REFCTX prefix — the GitHub-parity scan the tier guard unions in. Callers
  # pass a BOUNDARY-ANCHORED pattern (`\b${CLOSING_KW}`): without `\b` the class
  # matches inside English words and the scan is BROADER than GitHub (false
  # refusals). Default is the positional form "${REFCTX}${CLOSING_KW}",
  # mirroring check-pipeline-compliance.sh::parse_issue_ref.
  local text="$1" kwpat="${2:-}" kw
  if [ -n "$kwpat" ]; then kw="$kwpat"; else kw="${REFCTX}${CLOSING_KW}"; fi
  # a. full URLs.
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    local repo num
    repo="$(printf '%s' "$m" | tr 'A-Z' 'a-z' | grep -oE 'https://github.com/[^/[:space:],;)]+/[^/[:space:],;)]+/issues/[0-9]+' | sed -E 's#https://github.com/([^/]+/[^/]+)/issues/[0-9]+.*#\1#' | command head -1 || true)"
    num="$(printf '%s' "$m" | grep -oE '/issues/[0-9]+$' | grep -oE '[0-9]+' | command head -1 || true)"
    if [ -n "$repo" ] && [ -n "$num" ]; then
      printf '%s#%s\n' "$repo" "$num"
    fi
  done < <(printf '%s\n' "$text" | grep -ioE "${kw}[[:space:]]*https://github.com/[^/[:space:],;)]+/[^/[:space:],;)]+/issues/[0-9]+" || true)
  # b. owner/repo#<n> (exclude the URL class already matched in (a): the
  # owner/repo pattern requires the ref to START the token — URLs carry
  # https:// before the repo so they cannot match [^/[:space:],;)]+/
  # from token start after the keyword... guard by dropping any match whose
  # token contains "/issues/").
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    case "$m" in
      *issues/*) continue ;;
    esac
    local repo num
    repo="$(printf '%s' "$m" | grep -oE '[^/[:space:],;)]+/[^/[:space:],;)]+#[0-9]+$' | cut -d'#' -f1 || true)"
    num="$(printf '%s' "$m" | grep -oE '#[0-9]+$' | tr -d '#' || true)"
    if [ -n "$repo" ] && [ -n "$num" ]; then
      printf '%s#%s\n' "$repo" "$num"
    fi
  done < <(printf '%s\n' "$text" | grep -ioE "${kw}[[:space:]]*[^/[:space:],;)]+/[^/[:space:],;)]+#[0-9]+" || true)
  # c. bare #<n> → repo = $REPO.
  while IFS= read -r m; do
    [ -z "$m" ] && continue
    local num
    num="$(printf '%s' "$m" | grep -oE '#[0-9]+$' | tr -d '#' || true)"
    if [ -n "$num" ]; then
      printf '%s#%s\n' "$REPO" "$num"
    fi
  done < <(printf '%s\n' "$text" | grep -ioE "${kw}[[:space:]]*#[0-9]+" || true)
}

# ── clean-low content-shape predicates (#1348) ────────────────────────────
# The LOW CLASS. This is a POSITIVE, ANCHORED allowlist and it is deliberately
# NARROWER than the Low change-classification cell in proportional-gates
# (§Change Classification → the `Code impact` column's **Low** value:
# "Docs, config, CSS, strings only"): config and i18n strings can change runtime
# behaviour — issue #1348's own motivating regression (#4708, a CSP config
# change) IS a config change — so they are excluded, as are root instruction
# files and any enforcement input.
#         OVERRIDES: proportional-gates §Change Classification → Code impact →
#         Low ("Docs, config, CSS, strings only") — this class admits prose and
#         stylesheets only, never config or strings. NOTE that the §Review
#         Cycles table's Low ROW (1 reviewer, no cycle loop) is a DIFFERENT
#         artifact in the same file; conflating the two is what makes such a
#         marker hard to find, so the anchor above names the table and the
#         column explicitly.
#
# It is also deliberately narrower than the other two content-shape classes in
# this repo, and it must NOT be replaced by either:
#   * check-pipeline-compliance.sh::pr_is_artifact_only is check (a)'s
#     closure fallback: it admits ANY file under docs/ (so `docs/evil.sh` would
#     be an "artifact"), AGENTS.md and skills/**/*.md / templates/**/*.md
#     (agent-executable instructions — the template is the source that
#     materializes into every repo's AGENTS.md) and .github/CODEOWNERS (review
#     routing — enforcement input). No line numbers cited for either class:
#     both had rotted (the sibling was 5 lines out on 2026-10-06), so
#     `file::function` is the stable citation.
#   * extensions/verification-gate::isShapeExemptFile is a LOCAL
#     pre-flight skip; it admits .md/.css/.html ANYWHERE, including build
#     inputs such as templates/AGENTS.base.md. (After #1409 the closure class
#     admits that path too, but for a different reason and a different job:
#     check (a) asks "does this PR close an issue", the attestation class asks
#     "is this diff inert enough to carry a merge attestation". The divergence
#     stands and is deliberate.)
# A class is only as trustworthy as the gate it protects, and this one protects
# a merge attestation — hence the tightest of the three. The divergence is
# deliberate; sharing or copying one of the others here would make this guard
# inherit a class chosen for a different purpose.
#
# Layout rule, stated as an ANCHORED regex rather than a bash glob on purpose:
# in bash pattern matching `*` crosses `/`, so `*.md` would admit
# `.github/workflows/x.md` and `skills/code-review/SKILL.md` — every enforcement
# root this class exists to exclude.
CLEAN_LOW_DOCS_RE='^docs/[^/].*\.(md|markdown|txt|rst|adoc|css|scss)$'
# Root-level inert prose, by EXACT basename — never by extension. An extension
# rule at the root admits AGENTS.md / MEMORY.md / VENDOR.md (the always-loaded
# instruction and enforcement layer) and requirements.txt (a build input).
# .mdx and .html are absent from BOTH arms: MDX compiles JSX to JS and HTML can
# carry script, so neither is "prose".
clean_low_path_ok() {
  local p="$1"
  [ -n "$p" ] || return 1
  # A path carrying a RAW control character must not be admitted: git allows
  # them inside a filename, and a newline/tab splits one real file into several
  # well-formed-looking rows (each of which could pass the class on its own).
  # Defence in depth, NOT a live arm for this guard: its rows come from `jq
  # @tsv`, which ESCAPES \t and \n (`docs/c<LF>d.md` arrives as the literal
  # `docs/c\nd.md`), so a real one cannot reach here from that path — and an
  # ESCAPED one is an in-class filename, admitted on purpose. Kept for a caller
  # that feeds raw rows.
  case "$p" in
    *[$'\n\r\t']*) return 1 ;;
  esac
  case "$p" in
    /*|~*) return 1 ;;
  esac
  # Segment hygiene: no empty, no `.`, no `..` segment. Wrapping in `/` makes
  # the first and last segments match the same pattern as every interior one.
  case "/$p/" in
    *"//"*)   return 1 ;;
    *"/./"*)  return 1 ;;
    *"/../"*) return 1 ;;
  esac
  case "$p" in
    README.md|CHANGELOG.md|CONTRIBUTING.md|SECURITY.md|CODE_OF_CONDUCT.md) return 0 ;;
  esac
  grep -qE "$CLEAN_LOW_DOCS_RE" <<<"$p"
}

# clean_low_rows — read TSV rows ("<status>\t<filename>\t<old>") on stdin,
# validate the FRAMING, print the accepted rows. Same FRAMING as
# check-pipeline-compliance.sh::files_rows (NF==3, non-empty filename, the
# GitHub diff-entry status enum, `renamed` must carry its old path) with ONE
# deliberate divergence and no shared class: `copied`. `copied` is refused by
# ABSENCE from the accepted enum,
# not by an extra arm: a copy's source is absent from the file list, so a
# new-path-only check cannot see whether executable content was duplicated into
# a docs path. (The adjacent gate ACCEPTS `copied` for a closure fallback,
# where the residual is harmless; here it would be a merge attestation.) An
# explicit `if (s == "copied") exit 1` used to sit above the enum and was dead
# code — its removal changed nothing, so the suite could not catch it; the
# enum's absence is the live arm and IS covered.
clean_low_rows() {
  LC_ALL=C awk -F '\t' '
    {
      if (NF != 3) exit 1
      if ($2 == "") exit 1
      s = $1
      if (s != "added" && s != "modified" && s != "removed" && s != "renamed" && s != "changed" && s != "unchanged") exit 1
      if (s == "renamed" && $3 == "") exit 1
      print
    }
  '
}

# clean_low_shape_ok <rows> <expected-count> — the whole attestation: true only
# when EVERY changed path (BOTH ends of every row) is in the Low class.
clean_low_shape_ok() {
  local rows="$1" expected="$2" count paths p
  [ -n "$rows" ] || return 1
  # DISTINCT paths, not rows: `.changed_files` counts distinct paths while the
  # compare endpoint returns one entry per diff entry, so a delete+add pair is
  # two rows for one path. Comparing rows would falsely refuse such a PR.
  count="$(printf '%s\n' "$rows" | LC_ALL=C awk -F '\t' '{ print $2 }' | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  [ -n "$count" ] && [ "$count" -gt 0 ] || return 1
  # GitHub's compare endpoint returns at most 300 entries and does NOT paginate
  # the array, so AT the cap the list may be truncated. Refuse at the cap rather
  # than relying on a second API field to reveal the truncation.
  [ "$count" -lt 300 ] || return 1
  # The authoritative count is REQUIRED, not optional: an absent/unparseable
  # count means the truncation detector cannot run, and skipping the check
  # would be a fail-OPEN on exactly the arm that catches a short list. Refuse.
  grep -qE '^[1-9][0-9]*$' <<<"$expected" || return 1
  [ "$count" = "$expected" ] || return 1
  paths="$(printf '%s\n' "$rows" | LC_ALL=C awk -F '\t' '{ print $2; if ($3 != "") print $3 }')"
  [ -n "$paths" ] || return 1
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    clean_low_path_ok "$p" || return 1
  done <<< "$paths"
  return 0
}

# ── tortoise#7391 — the review-artifact evidence gate (fresh `clean` records) ────
# A `clean` record is the only verdict that asserts a review HAPPENED and
# cannot be cross-checked from anything else on disk, so the caller must name
# the artifact it rests on and this script must be able to read it back.
# Everything here is FAIL-CLOSED: an unparseable ref, an unreadable artifact,
# an unreadable commit date, or a REST call that failed all refuse. A
# verification that degraded to a pass would be this same defect one layer up.

# Accepted reference shapes → "<kind>\t<id>". Nothing else is guessed at.
evidence_ref_split() { # <ref> -> "<kind>\t<id>"; rc 1 = not a recognisable artifact ref
  local ref="$1" kind="" id=""
  # A ref carrying a quote, a backslash or ANY control character could break
  # the record's JSON framing further down, and no legitimate ref contains one
  # — refuse rather than escape (the same fail-closed posture as clean_low_path_ok).
  # The whole C0 range is refused, not an enumerated list: a raw CR / BEL / escape
  # slipped past the earlier `\n`/`\t`-only case and reached the record as
  # `"evidence":"…\r…"`, which BOTH jq and Python json then reject as an invalid
  # control character (review-enforcer: JSON.parse throws -> no record read).
  # The backslash arm must match ONE backslash. `*'\\'*` is the two-character
  # string `\\` (quoted pattern characters are literal), so it only ever fired on
  # a pair — and a single-backslash ref slipped through to the record as
  # `"evidence":"…\#…"`, an invalid JSON escape that BOTH jq and Python json
  # reject (the record then reads as absent, which fails closed at the merge gate
  # but silently: the lane was told the evidence verified). `*"\\"*` is one
  # literal backslash (reviewer B, cycle 2).
  if [[ "$ref" == *'"'* || "$ref" == *"\\"* || "$ref" =~ [[:cntrl:]] ]]; then return 1; fi
  case "$ref" in
    *"/pull/"*"#issuecomment-"*)      kind="comment";        id="${ref##*#issuecomment-}" ;;
    *"/issues/"*"#issuecomment-"*)    kind="comment";        id="${ref##*#issuecomment-}" ;;
    *"/pull/"*"#discussion_r"*)       kind="review-comment"; id="${ref##*#discussion_r}" ;;
    *"/pull/"*"#pullrequestreview-"*) kind="review";         id="${ref##*#pullrequestreview-}" ;;
    comment:*|issuecomment:*)          kind="comment";        id="${ref#*:}" ;;
    review:*)                          kind="review";         id="${ref#*:}" ;;
    review-comment:*|discussion:*)     kind="review-comment"; id="${ref#*:}" ;;
    *) return 1 ;;
  esac
  # The id must be purely numeric AND the whole tail: `comment:12x` is not a
  # ref, and neither is a URL fragment with trailing junk.
  [[ "$id" =~ ^[0-9]+$ ]] || return 1
  printf '%s\t%s' "$kind" "$id"
}

# One gh read per artifact, emitting "<created_at>\t<parent_url>\t<body>\t<state>".
# `@tsv` keeps the body on ONE line (newlines escaped), so the caller reads
# four fields with a single `read` and never needs an external jq. Only the
# review arm has a `state`; the other arms emit three fields and `read` leaves
# the fourth empty.
evidence_fetch() { # <kind> <id> -> tsv row; non-zero = unreadable
  case "$1" in
    comment)
      command gh api "repos/$REPO/issues/comments/$2" \
        --jq '[(.created_at // ""), (.issue_url // ""), (.body // "")] | @tsv' 2>/dev/null ;;
    review)
      # `.state` is GitHub's OWN machine-readable verdict on the review
      # (APPROVED | CHANGES_REQUESTED | COMMENTED | DISMISSED | PENDING) and is
      # carried out for the explicit check below: a CHANGES_REQUESTED review
      # whose body happens to veto-match nothing is still not clean evidence,
      # and no body-text widen can close that (reviewer B, P2).
      command gh api "repos/$REPO/pulls/$PR/reviews/$2" \
        --jq '[(.submitted_at // .created_at // ""), (.pull_request_url // ""), (.body // ""), (.state // "")] | @tsv' 2>/dev/null ;;
    review-comment)
      command gh api "repos/$REPO/pulls/comments/$2" \
        --jq '[(.created_at // ""), (.pull_request_url // ""), (.body // "")] | @tsv' 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# Verify that <ref> is a review artifact attesting THIS PR at <head>.
# Prints one confirmation line on success; prints WHY on stderr and returns 1.
verify_review_evidence() { # <ref> <head_sha> -> 0 = verified
  local ref="$1" head="$2" split kind id row created parent body state head_date _rest
  if [ -z "$REPO" ] || ! command -v gh >/dev/null 2>&1; then
    echo "   cannot verify review evidence without a repo and the gh CLI (repo='${REPO:-<none>}') — pass <owner/repo> explicitly so the artifact can be read." >&2
    return 1
  fi
  if ! split="$(evidence_ref_split "$ref")"; then
    echo "   not a recognisable review-artifact reference: '$ref'" >&2
    echo "   accepted: comment:<id>, review:<id>, review-comment:<id>, or the GitHub URL of one of those." >&2
    return 1
  fi
  kind="${split%%$'\t'*}"
  id="${split##*$'\t'}"
  if ! row="$(evidence_fetch "$kind" "$id")" || [ -z "$row" ]; then
    echo "   could not read $kind $id from $REPO — it does not exist, or the API is unreachable. A FAILED READ IS NOT EVIDENCE: retry rather than record." >&2
    return 1
  fi
  # Fields are split MANUALLY, never with `IFS=$'\t' read`: tab is an IFS
  # WHITESPACE character, so `read` collapses an empty field. A review whose body
  # is empty (`TS\tPARENT\t\tCHANGES_REQUESTED`) then parsed as
  # body="CHANGES_REQUESTED", state="" — the state guard below short-circuited on
  # an empty `state` and a changes-requested review with inline comments and no
  # prose was ACCEPTED, minting `clean` (reviewer B, cycle 2: reproduced against
  # this function with real `jq @tsv` framing). The `%%`/`#` splits preserve empty
  # fields wherever they fall.
  created="${row%%$'\t'*}"; _rest="${row#*$'\t'}"
  parent="${_rest%%$'\t'*}"; _rest="${_rest#*$'\t'}"
  body="${_rest%%$'\t'*}"; state="${_rest#*$'\t'}"
  # The comment / review-comment arms emit three fields and carry no state; when
  # the split left `_rest` intact there was no 4th field to take.
  [ "$state" = "$_rest" ] && state=""
  # ON THIS PR: a comment on some other PR is not this PR's evidence.
  case "$kind" in
    comment)
      case "$parent" in */issues/"$PR") ;; *) echo "   $kind $id does not belong to $REPO#$PR (parent: ${parent:-unknown})" >&2; return 1 ;; esac ;;
    *)
      case "$parent" in */pulls/"$PR") ;; *) echo "   $kind $id does not belong to $REPO#$PR (parent: ${parent:-unknown})" >&2; return 1 ;; esac ;;
  esac
  # NOT the attestation itself: a record MARKER is not a review of the code.
  # Anchored to a LINE START, not to position 0: the body arrives @tsv-escaped,
  # so its newlines are the two characters `\n` and the whole comment is ONE
  # line — `^` alone matched only a body that was nothing BUT a marker, and a
  # marker introduced by any preceding line was accepted (reviewer B, P2).
  if grep -qE '(^|\\n)review recorded: reviews/' <<<"$body"; then
    echo "   $kind $id is a record marker, not a review artifact — it attests that a verdict was recorded, which is the very thing this check exists to stop taking on trust." >&2
    return 1
  fi
  # GITHUB'S OWN VERDICT ON A REVIEW. PR reviews carry a machine-readable state;
  # anything but APPROVED/COMMENTED (i.e. CHANGES_REQUESTED, DISMISSED, PENDING)
  # is not evidence of a clean review whatever its body says.
  if [ -n "$state" ] && [[ ! "$state" =~ ^(APPROVED|COMMENTED)$ ]]; then
    echo "   $kind $id is a $state review — a review that requested changes, was dismissed, or never concluded is not evidence of a clean review." >&2
    return 1
  fi
  # POSTDATES THE RECORDED REVISION. Without this the lane can name a clean
  # artifact from an earlier head, which is how an unreviewed head gets a
  # verdict minted on it (tortoise#7391's own reproduction: two PRs whose
  # current diffs were never reviewed, recorded clean via their current head).
  head_date="$(command gh api "repos/$REPO/commits/$head" --jq '.commit.committer.date // ""' 2>/dev/null || true)"
  if ! [[ "$head_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "   could not read the commit date of the recorded head ${head:0:12}… — cannot show the artifact postdates the revision it would attest." >&2
    return 1
  fi
  if ! [[ "$created" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]; then
    echo "   $kind $id carries no readable created_at timestamp." >&2
    return 1
  fi
  # Same ISO-8601 Z format on both sides, so the string compare IS the time compare.
  if [[ "$created" < "$head_date" ]]; then
    echo "   $kind $id was created $created, BEFORE the recorded head's commit date $head_date — it cannot attest a revision that did not exist yet." >&2
    return 1
  fi
  # A NOT-CLEAN artifact is evidence a review FAILED. tortoise#3549 carried six
  # comments and every one of them said NOT CLEAN, so existence alone would let
  # a lane name one of them and still mint `clean`.
  #
  # A LITERAL "not clean" match is NOT enough — found by the tortoise#7391 scoping
  # verifier, reproduced against the review skills' OWN templates. The
  # `code-review` skill's Step 8 header for a review that ends with UN-FIXED
  # issues is
  #     "⚠️ Auto-fix [stalled after N cycles | failed: <reason>] — M issues
  #      require human attention"
  # which contains no `not…clean` substring at all, yet is exactly the
  # documentation of a failed review this arm exists to reject. The veto
  # therefore also matches the unresolved-exit vocabulary the review skills
  # emit: the stalled/failed auto-fix header, "require(s) human attention", and
  # "N issues remain" (the cap markers).
  #
  # The veto names the UNRESOLVED-exit vocabulary the review skills actually
  # emit, plus the digits-guarded remain form. It deliberately does NOT match
  # "Found N issues" (the CLEAN template lists issues that were FIXED) or the
  # bare phrase "issues remain" (a clean review reports "No issues remain after
  # the fixes"): either would false-refuse a legitimate clean record and deadlock
  # the lane, which is why the remain form requires a leading COUNT and the
  # unresolved form requires the word "unresolved". Exact emissions covered:
  #   "## Review — NOT CLEAN"                                  (13f)
  #   "⚠️ Auto-fix stalled after N cycles … requires human review"
  #   "⚠️ Auto-fix made no changes for 2 consecutive cycles (zero-progress) …"
  #   "⚠️ Auto-fix converged with issues unresolved — requires human review"
  #   "⚠️ Auto-fix stuck (honest-stuck …) — requires human review"
  #   "⚠️ Auto-fix aborted (tool-unavailable|push-failed|git-error|pr-closed) …"
  #   "⚠️ Auto-fix reached the 10-cycle safety cap — unresolved issues remain"
  #   "⚠️ Test review capped at 10 cycles — N issues remain:"   (literal N)
  #   "Requires Human Input / Requires Human Attention"        (plan-review block)
  #   "[ADVERSARIAL-BOUND] cycles=… threats=… covered=… residuals=…"
  # Every prefix above is quoted from `skills/code-review/references/fixer-loop.md
  # §"PR comment prefix"` — the file that OWNS the vocabulary — because an earlier
  # revision of this arm hard-coded a PARAPHRASE ("human attention") of the skill's
  # actual marker ("requires human review") and therefore admitted four of the
  # seven unresolved prefixes verbatim, reproducing the tortoise#3549 shape:
  # a lane whose review ABORTED could name its own Step-8 comment and mint clean.
  # An unresolved-exit prefix that this list does not name is a fail-open, so
  # extend it from fixer-loop.md, never from memory.
  if grep -qiE 'not[[:space:]_-]*clean|auto-fix[[:space:]]+(stalled|failed|reached|aborted|converged|stuck)|require[s]?[[:space:]]+human[[:space:]]+(attention|input|review)|unresolved[[:space:]]+issues?|[0-9]+[[:space:]]+issues?[[:space:]]+remain|test[[:space:]]+review[[:space:]]+capped|\[ADVERSARIAL-BOUND\]' <<<"$body"; then
    echo "   $kind $id asserts an UNRESOLVED outcome (NOT-CLEAN, or a stalled/failed/cap/human-input exit) — it is evidence the review did not conclude clean." >&2
    return 1
  fi
  printf '%s %s on %s#%s, created %s, postdates head %s\n' "$kind" "$id" "$REPO" "$PR" "$created" "${head:0:12}"
  return 0
}

# ── main (guarded — executable when run, inert when sourced for tests) ────
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
# ── #980: the second-model subsystem was removed ────────────────────────
# These env vars used to feed the [SECOND-MODEL-GATE] marker. Ignoring them
# SILENTLY would write a plain `clean` record while the caller believes
# second-model evidence was captured — a false green. Refuse instead.
for _v in SECOND_MODEL_GATE_MODEL SECOND_MODEL_GATE_INDEPENDENT; do
  if [ -n "${!_v:-}" ]; then
    echo "record-review.sh: \$${_v} is set, but the second-model gate was removed (#980/#979) — it would be silently ignored, so this record would not carry the evidence you expect. Unset it and re-run." >&2
    exit 2
  fi
done

# Scan args for --force-stale (any position); everything else stays
# positional — but an UNKNOWN option is REFUSED, never silently dropped.
# Only $1..$4 are read, so a dropped trailing flag used to shift the repo
# position and still write a record with rc=0.
FORCE_STALE=0
EVIDENCE=""
# tortoise#7391: what the record carries. Set ONLY by the verification gate below, so a
# record claims `evidence` only when this run actually read and accepted that
# artifact — passing --evidence on a path the gate does not cover (a carry, a
# non-clean verdict) cannot put an unverified claim in the record.
EVIDENCE_VERIFIED=""
POSITIONAL=()
_argv=("$@")
_i=0
while [ "$_i" -lt "${#_argv[@]}" ]; do
  _arg="${_argv[$_i]}"
  case "$_arg" in
    --force-stale) FORCE_STALE=1 ;;
    --evidence)
      # tortoise#7391: consumes the NEXT argument (the review-artifact reference).
      _i=$((_i + 1))
      if [ "$_i" -ge "${#_argv[@]}" ]; then
        echo "record-review.sh: --evidence needs a value — usage: record-review.sh <pr> <head_sha> [verdict] [repo] [--evidence <review-artifact>] [--force-stale]" >&2
        exit 2
      fi
      EVIDENCE="${_argv[$_i]}" ;;
    --second-model|--second-model-independent)
      echo "record-review.sh: '$_arg' was removed with the second-model subsystem (#980/#979) — this repo is single-model; refusing to record. Drop it from the invocation." >&2
      exit 2 ;;
    -*) echo "record-review.sh: unknown option '$_arg' — the second-model gate was removed (#980/#979). usage: record-review.sh <pr> <head_sha> [verdict] [repo] [--evidence <review-artifact>] [--force-stale]" >&2
        exit 2 ;;
    *) POSITIONAL+=("$_arg") ;;
  esac
  _i=$((_i + 1))
done
if [ "${#POSITIONAL[@]}" -gt 4 ]; then
  echo "record-review.sh: too many arguments (${#POSITIONAL[@]}) — usage: record-review.sh <pr> <head_sha> [verdict] [repo] [--evidence <review-artifact>] [--force-stale]" >&2
  exit 2
fi
if [ "${#POSITIONAL[@]}" -gt 0 ]; then
  set -- "${POSITIONAL[@]}"
else
  set --
fi
PR="${1:?usage: record-review.sh <pr> <head_sha> [verdict] [repo] [--force-stale] [--evidence <artifact>]}"
SHA="${2:?missing head_sha}"
VERDICT="${3:-clean}"
REPO="${4:-}"
case "$VERDICT" in
  clean|clean-micro|clean-low) ;;
  *) echo "verdict must be 'clean', 'clean-micro' or 'clean-low'; refusing to record '$VERDICT'" >&2; exit 2 ;;
esac
# ── clean-low × --force-stale is an argument-level contradiction (#1348) ──
# clean-low certifies the CONTENT SHAPE OF A SPECIFIC REVISION. --force-stale
# exists to record a sha the PR no longer points at; every consumer of this
# record keys on the PR, not the sha, so the shape a reader would act on is not
# the shape that was certified. Refuse the combination rather than mint a
# certified-for-the-wrong-revision record (exit 2 — an argument error, like an
# unknown option; no record written).
if [ "$VERDICT" = "clean-low" ] && [ "$FORCE_STALE" -eq 1 ]; then
  echo "record-review.sh: --force-stale is incompatible with the clean-low verdict — clean-low certifies the content shape of a specific revision, and the sha a stale record names is not the revision any consumer will read. Re-run at the current head without --force-stale." >&2
  exit 2
fi
# Input validation (#2055): the ai-review-gate binds the FULL 40-char sha and
# a numeric PR — reject bad inputs up front rather than posting evidence that
# can never verify.
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  echo "PR number must be numeric; refusing to record '$PR'" >&2; exit 2
fi
if ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "head_sha must be a full 40-char hex sha (got '${SHA:0:12}…'); refusing to record" >&2; exit 2
fi
# tortoise#7391: the sha the CALLER named, kept before any carry re-binds $SHA to the
# current head. A carried record's `carried_from` (and the head the recovered
# mint time belongs to) is this one, not the head it is carried onto.
ORIG_SHA="$SHA"
# Set by the carry arms below; initialised here so the tortoise#7391 evidence gate can
# read it unconditionally under `set -u`.
CARRY_ARM=""
# Auto-detect repo (owner/name) when not passed explicitly. Detect BEFORE
# format-checking: an omitted repo is legal here (auto-detected), and when
# nothing is detectable the record proceeds repo-less for backward compat.
if [ -z "$REPO" ]; then
  REPO="${GH_REPO:-}"
fi
if [ -z "$REPO" ]; then
  REPO="$(command gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
fi
if [ -n "$REPO" ] && ! [[ "$REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
  echo "repo must be owner/name (got '$REPO'); refusing to record" >&2; exit 2
fi
# ── Diff binding (#2982, normalized by #1362 D1) ──────────────────────────
# What a review approves is the DIFF, not the commit sha. Record the sha256 of
# the PR's three-dot diff and carry it INSIDE the signed marker so the
# ai-review-gate can accept a verdict across a merge-only branch update
# (`gh pr update-branch` inserts a merge commit; the head sha moves, the
# reviewed diff does not). Without this, `strict: true` branch protection and
# the gate's sha-binding were jointly unsatisfiable: every update invalidated
# a still-correct verdict, so a green PR could never reach a terminal
# mergeable state (#2982).
#
# #1362 D1 (owner ruling 2026-09-23): the digest is computed over the
# NORMALIZED diff, not the raw byte rendering. A base update (rebase /
# `gh pr update-branch`) rewrites `index <blob>..<blob>` lines and the hunk
# headers' start-line numbers even when every changed line is identical —
# measured on tortoise #4841: byte count identical (137,767), exactly 6 lines
# differ, and `git patch-id --stable`/`--verbatim` both MATCH while the raw
# diff hash did not (5 of 6 sampled BEHIND PRs refused a still-correct
# verdict). Those refusals are false obligations: the change is identical;
# only derived rendering moved. The normalization drops the `index` line
# exactly when the ENTRY's hunk content already carries the change, and zeros
# the hunk-header start lines; hunk CONTENT and COUNTS are untouched (counts
# derive from content, so they move only when content moves).
#
# #1362 AMENDMENT (2026-09-23, recorded on the issue): the drop is
# ENTRY-SCOPED. A binary entry has NO hunk, so its `index` line is its ONLY
# content-bearing field — dropping it made two different binaries at the same
# path normalize to the SAME digest, a fail-open in a required merge gate
# (sign a marker over binary v1, swap in v2, the gate accepts an unreviewed
# binary). Rule: drop the `index` line exactly when the hunk content already
# carries the change; keep it verbatim otherwise (binary entries, and the
# hunk-less empty-file add/delete). The predicate is hunk presence, never a
# binary marker. Implemented in the shared normalizer — see its docstring.
#
# THE BINDING STAYS A SHA256 over content — deliberately NOT `git patch-id`:
# `--stable` and the default both IGNORE whitespace (a false ACCEPT: a
# whitespace-only edit would carry a verdict it does not deserve), and a SHA-1
# sum is weaker than a sha256. `--verbatim` closes the whitespace hole but not
# the primitive's weakness.
#
# The normalizer is the ONE shared implementation — scripts/lib/diff-normalize.py,
# resolved from THIS script's own directory so the repo copy and the farmed
# ~/.pi/agent/scripts copy both find it. It is a CROSS-REPO CONTRACT with the
# consumer (tortoise .github/workflows/ai-review-gate.yml): both sides must
# normalize IDENTICALLY or every freshly-signed marker stops matching.
#
# The bytes MUST come from the GitHub REST API, exactly as the workflow does —
# a local `git diff` would not byte-match and every diff= marker would fail
# closed. Hash the FILE, not a command substitution: `x="$(cmd)"` strips
# trailing newlines and would change the digest.
#
# Empty when gh/API/openssl is unavailable → the marker falls back to the
# legacy sha-only shape, and the gate's sha-match path still governs.
DIFF_NORMALIZER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/diff-normalize.py"
DIFF_HASH=""
# #1362 D1 — the sha256 over the RAW diff (the pre-normalization binding). Kept
# ONLY so the carry-forward arm can accept a marker minted before this change;
# nothing else reads it. Both hashes come from ONE diff fetch.
LEGACY_DIFF_HASH=""
# #1577 — how the diff read ENDED, so the warning can name the condition instead
# of implying a content change:
#   "ok"          the body was read
#   "empty"       a 2xx whose body was 0 bytes    (a property of the DIFF)
#   "unavailable" a failed read, or no read at all (a property of the NETWORK)
# Only the first two can mean "a fresh review is owed"; the third means "retry".
# The stale-sha guard already states this policy for the HEAD read ("a transient
# gh/API failure must not block a legitimate record", see the block below), but
# the DIFF read is the one that actually refused: an empty DIFF_HASH leaves the
# carry nothing to compare, and the refusal it produced -- "the reviewed diff
# CHANGED" -- demands the MOST expensive remedy in the system.
DIFF_FETCH="unavailable"
DIFF_FETCH_TRIES=0
# The fetch is RETRIED. A single attempt made a transient API blip
# indistinguishable from a changed artifact. Measured on agent-infra #1554: a
# full rail cycle ([1/4] base refresh + ~45 min of [2/4] terminal-CI wait +
# [3/4]) was discarded on a diff that was BYTE-IDENTICAL (diff=72bd1a21 on both
# heads); the same command succeeded on the next attempt. The read is an
# idempotent GET, so retrying has no side effects. Both knobs are
# env-overridable so the suite can pin the attempt count without paying for the
# backoff.
# The attempt budget is validated the same way the backoff is, and for the same
# reason: `"${...:-3}"` accepts ANY run of digits. A huge in-range value made the
# loop effectively unbounded on a persistently failing fetch (234 attempts in
# ~6s at a zero backoff; one attempt per poll at the default), and a NON-numeric
# value leaked a raw `[: abc: integer expression expected` into the rail's log
# and produced a nonsense "1 of abc attempt(s) made" (#1577 review P3). An
# unusable value falls back to the DEFAULT rather than to the cap, so a typo
# reads as the documented behaviour instead of silently widening the budget.
DIFF_FETCH_ATTEMPTS_MAX=10
DIFF_FETCH_ATTEMPTS=3
case "${RECORD_REVIEW_DIFF_FETCH_ATTEMPTS:-}" in
  ''|*[!0-9]*) : ;;
  *)
    if [ "${#RECORD_REVIEW_DIFF_FETCH_ATTEMPTS}" -le 2 ] \
       && [ "$RECORD_REVIEW_DIFF_FETCH_ATTEMPTS" -ge 1 ] \
       && [ "$RECORD_REVIEW_DIFF_FETCH_ATTEMPTS" -le "$DIFF_FETCH_ATTEMPTS_MAX" ]; then
      DIFF_FETCH_ATTEMPTS="$RECORD_REVIEW_DIFF_FETCH_ATTEMPTS"
    fi
    ;;
esac
# The backoff is CLAMPED to a small non-negative integer, and that is NOT
# belt-and-braces. The obvious guard (a `case` rejecting non-digits plus a
# `-gt 0` test) accepts ANY run of digits, and an all-digit value past
# /bin/sleep's range (2147483648) makes sleep exit 1 -- under `set -e` that
# aborted the ENTIRE record with no warning and NO record written, while an
# in-range-but-huge value (999999999) hung it for years. Both were reproduced
# end-to-end against a failing fetch. This repo closes the same class for the
# rail poll intervals (atomic-land `--poll` 7e, admin-merge P2-12), but those
# REFUSE rc 2: here the knob is pure politeness, and a mistyped backoff must
# never cost the attestation, so it clamps instead of failing.
DIFF_FETCH_SLEEP_MAX=30
DIFF_FETCH_SLEEP_RAW="${RECORD_REVIEW_DIFF_FETCH_SLEEP:-2}"
DIFF_FETCH_SLEEP=0
case "$DIFF_FETCH_SLEEP_RAW" in
  ''|*[!0-9]*) : ;;                       # non-numeric → no sleep at all
  *)
    # The LENGTH test guards the numeric one: `[ <20 digits> -le 30 ]` errors,
    # and a shell that treated that as fatal would reintroduce the abort. Only
    # short strings reach the comparison, so it is always well-formed.
    if [ "${#DIFF_FETCH_SLEEP_RAW}" -le 2 ] \
       && [ "$DIFF_FETCH_SLEEP_RAW" -le "$DIFF_FETCH_SLEEP_MAX" ]; then
      DIFF_FETCH_SLEEP="$DIFF_FETCH_SLEEP_RAW"
    else
      DIFF_FETCH_SLEEP="$DIFF_FETCH_SLEEP_MAX"
    fi
    ;;
esac
# ONE diff read into <out>. The EXIT STATUS carries the reason, which the old
# `cmd && [ -s ]` one-liner threw away: 0 = read, 1 = the call FAILED (retryable),
# 2 = the call SUCCEEDED with a 0-byte body (NOT retryable -- an idempotent GET
# answers the same thing twice, so re-asking cannot change the answer).
diff_fetch_once() { # <pr> <out>
  command gh api -H "Accept: application/vnd.github.v3.diff" \
    "repos/$REPO/pulls/$1" > "$2" 2>/dev/null || return 1
  [ -s "$2" ] || return 2
  return 0
}
# Sets the globals DIFF_HASH (normalized) and LEGACY_DIFF_HASH (raw) from one
# diff fetch. It deliberately sets GLOBALS rather than printing: a `$(...)`
# capture would run the assignment in a subshell and lose LEGACY_DIFF_HASH.
diff_hash_for_pr() { # <pr>
  local pr="$1" tmp norm attempt=1 rc=0
  command -v gh >/dev/null 2>&1 || return 0
  command -v openssl >/dev/null 2>&1 || return 0
  tmp="$(mktemp 2>/dev/null)" || return 0
  norm="$(mktemp 2>/dev/null)" || { rm -f "$tmp"; return 0; }
  # `EXIT`, deliberately NOT `RETURN` (#1577 review P1). A RETURN trap is
  # INHERITED by nested functions under functrace, so the trap fired when
  # `diff_fetch_once` returned and deleted $tmp BEFORE the hash read it: the
  # record aborted rc 1 with NO record written, on EVERY successful fetch. The
  # parent had no nested call inside this window, so the abort was introduced by
  # extracting the fetch into a function. Functrace reaches this process only
  # from an explicit `bash -T` or an ancestor that EXPORTED SHELLOPTS -- `set -T`
  # alone does NOT export it (review P3: the first draft of this comment claimed
  # it did, and that propagation mechanism was measurably false). The function's
  # own `rm -f` at the end is the normal cleanup; EXIT is only the backstop.
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' '$norm'" EXIT 2>/dev/null || true
  while :; do
    rc=0
    diff_fetch_once "$pr" "$tmp" || rc=$?
    DIFF_FETCH_TRIES="$attempt"
    if [ "$rc" -eq 1 ] && [ "$attempt" -lt "$DIFF_FETCH_ATTEMPTS" ]; then
      attempt=$(( attempt + 1 ))
      if [ "$DIFF_FETCH_SLEEP" -gt 0 ]; then
        # `|| true`: the DELAY is polite, the RECORD is not. A failing sleep
        # must never abort the attestation under `set -e`.
        sleep "$DIFF_FETCH_SLEEP" || true
      fi
      continue
    fi
    break
  done
  case "$rc" in
    0) DIFF_FETCH="ok" ;;
    2) DIFF_FETCH="empty" ;;
    *) DIFF_FETCH="unavailable" ;;
  esac
  if [ "$DIFF_FETCH" = "ok" ]; then
    LEGACY_DIFF_HASH="$(command openssl dgst -sha256 < "$tmp" | awk '{print $NF}')"
    if command -v python3 >/dev/null 2>&1 && [ -f "$DIFF_NORMALIZER" ] \
       && [ -s "$DIFF_NORMALIZER" ] \
       && python3 "$DIFF_NORMALIZER" < "$tmp" > "$norm" 2>/dev/null \
       && [ -s "$norm" ]; then
      DIFF_HASH="$(command openssl dgst -sha256 < "$norm" | awk '{print $NF}')"
    else
      # Fail OPEN to the pre-#1362 raw digest: the consumer still accepts it as
      # the legacy hash, so the marker stays verifiable — but a base-only update
      # will keep refusing carry-forward. Name that loudly rather than minting a
      # digest no consumer can verify.
      #
      # `[ -s ]` on the SOURCE and on the OUTPUT is load-bearing (#1362 review):
      # a zero-byte normalizer exits 0 and prints NOTHING, so without the output
      # check `$norm` is empty and DIFF_HASH becomes sha256("") — a CONSTANT that
      # collides for every diff and lets the carry-forward arm mint head-bound
      # evidence for an unreviewed revision (a false accept). Absent, unreadable,
      # failing, and empty all take this raw-digest arm.
      echo "⚠️ #1362: the diff normalizer is unavailable or produced no output (need a non-empty python3 + $DIFF_NORMALIZER) — hashing the RAW diff; a base-only update will keep refusing carry-forward until it is installed" >&2
      DIFF_HASH="$LEGACY_DIFF_HASH"
    fi
  fi
  rm -f "$tmp" "$norm"
}
if [ -n "$REPO" ]; then
  diff_hash_for_pr "$PR"
  [[ "$DIFF_HASH" =~ ^[0-9a-f]{64}$ ]] || DIFF_HASH=""
  [[ "$LEGACY_DIFF_HASH" =~ ^[0-9a-f]{64}$ ]] || LEGACY_DIFF_HASH=""
  if [ -z "$DIFF_HASH" ]; then
    case "$DIFF_FETCH" in
      empty)
        # A 2xx with no bytes IS a statement about the diff, so it is neither
        # retried nor described as a network failure (#1577).
        echo "⚠️ #2982: could not compute this PR's diff hash — the API answered and the diff body was EMPTY (0 bytes). Recording a legacy sha-only marker; it will NOT carry across a branch update" >&2 ;;
      *)
        echo "⚠️ #2982: could not compute this PR's diff hash — the diff fetch FAILED (gh/API/openssl unavailable; ${DIFF_FETCH_TRIES} of ${DIFF_FETCH_ATTEMPTS} attempt(s) made). A FAILED FETCH IS NOT A CHANGED ARTIFACT: retry the record before paying for a fresh review. Recording a legacy sha-only marker, which will NOT carry across a branch update" >&2 ;;
    esac
  fi
fi

# ── Stale-sha guard (#2133, extended by #2982): $SHA must be the CURRENT head
# The ai-review-gate binds the recorded FULL sha into the signed marker. PR
# #2074 recorded a stale-but-well-formed sha (…d329… vs real head …1ebe…,
# both under short prefix 4cb7e671), causing repeated gate failures that
# masqueraded as "No AI review evidence". Refuse mismatches up front unless
# --force-stale is passed. Fail-OPEN when the head cannot be fetched (a
# transient gh/API failure must not block a legitimate record); skip when no
# repo is detectable (backward compat — record as before).
#
# ── Gate key (#2055), hoisted for #784 ─────────────────────────────────────
# Resolved BEFORE the stale-sha guard, because the carry-forward arm must VERIFY
# a prior marker's HMAC before treating it as evidence. The PR body is
# attacker-writable, so a shape-only `sig=[0-9a-f]{64}` check lets a forged
# `sig=<64 zeros>` line be carried forward and RE-SIGNED with the real key —
# minting a genuine attestation at the current head for a diff nobody reviewed.
GATE_KEY="${AI_REVIEW_GATE_KEY:-}"
if [ -z "$GATE_KEY" ] && [ -f "$HOME/.pi/agent/.ai-review-gate-key" ]; then
  GATE_KEY="$(cat "$HOME/.pi/agent/.ai-review-gate-key" 2>/dev/null || true)"
fi
# Normalize the key exactly like the workflow does (secrets arrive clean, but a
# file/env key may carry stray whitespace).
GATE_KEY="$(printf '%s' "$GATE_KEY" | tr -d '[:space:]')"

# ── LANE-DIMENSION CARRY (#6072/#6213/#4823) ─────────────────────────────
# The #2982 arm below asks whether the RENDERED patch is byte-identical. A base
# move breaks that whenever main's landed commits OVERLAP the files the PR
# touches, because the patch's "before" side then becomes main's new content while
# the LANE's contribution is unchanged. Measured on three PRs, all with zero lane
# commits between the reviewed head and the live head:
#   #6072  two base merges  -> record dead (stored diff != live diff)
#   #6213  one base merge   -> ai-review-gate SUCCESS at the reviewed head, then
#                             FAILURE 7 SECONDS after the rail moved the head
#   #4823  one base merge   -> a replacement record had to be produced (a fresh
#                             review paid for work that did not change)
# And one counter-example that fixes the boundary: #5421 also moved its head, but a
# real lint fix (cfe2bad0afaa) landed in between, so the refusal was CORRECT, a
# fresh review was owed, was produced, and the PR merged. This arm must fire on the
# first three and NOT on that one.
#
# This does NOT relax the head binding: the carry is re-recorded against
# CURRENT_HEAD, so the marker still names the head that merges. It widens WHEN a
# carry is permitted, from "the rendered text is identical" to "the LANE's commits
# are provably identical".
#
# FAIL-CLOSED: every clause below returns non-zero on any doubt (missing object,
# unreadable base, merge-tree unavailable, conflict), so the existing refusal path
# still governs. It DOES accept verdicts the #2982 arm rejected — that is its purpose,
# and the call site prints the reason ("the rendered diff changed"). What it proves is
# NARROWER than "the reviewed artifact unchanged": it proves the LANE's commits are
# identical, i.e. the head's tree is exactly a clean merge of the reviewed tree with the
# head's base parent. An earlier version of this line claimed the opposite and a reviewer
# falsified it — the claim would have licensed reverting this to a no-op extension.
# Replace refs and the grafts FILE, either of
# which could present a different commit graph to this check, are neutralised for its
# duration below — the two are DIFFERENT mechanisms and need different env vars.
lane_dimension_carry() { # <reviewed-sha> <current-head> -> 0 = provably unchanged
  local reviewed="$1" current="$2" base_sha="" p2="" merged="" mrc=0 ctree="" extra="" rc=0
  # Replace refs AND the grafts FILE both rewrite what rev-list, rev-parse and
  # rev-parse^{tree} SEE, so either one can present a different commit graph to this
  # predicate than the one that is really there — reviewers built BOTH and turned a
  # REFUSE fixture into a CARRY with unreviewed content in the head tree.
  # `GIT_NO_REPLACE_OBJECTS` covers ONLY `refs/replace/*`. A reviewer measured that a
  # `.git/info/grafts` line STILL carried under it (walk emptied, verdict CARRY), and that
  # `GIT_GRAFT_FILE=/dev/null` is what actually disables the file mechanism — reproduced
  # independently before this line was written, because the first version of this comment
  # claimed "Replace/graft refs ... are neutralised" while only replace refs were.
  # `local -x` scopes both exports to this function; the rest of the script is unaffected.
  local -x GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null
  [ -n "$reviewed" ] && [ -n "$current" ] || return 1
  [ "$reviewed" != "$current" ] || return 1

  # (A) BOTH revisions must be present locally. Deliberately NO `git fetch` here:
  # this is the trust boundary of the merge gate, and pulling objects from the
  # remote inside it is a worse failure than a missed carry. Absent object =>
  # refuse. (The base IDENTITY below still comes from the API — that is a read of
  # the PR's declared base, not a fetch of content, and an earlier version of this
  # comment wrongly implied the function made no network call at all.)
  command git cat-file -e "$reviewed^{commit}" 2>/dev/null || return 1
  command git cat-file -e "$current^{commit}" 2>/dev/null || return 1

  # (B) THE HEAD MOVED FORWARD. A rewritten/rebased head is a DIFFERENT artifact
  # even when its lane commits look equivalent, so it must never carry this way.
  command git merge-base --is-ancestor "$reviewed" "$current" 2>/dev/null || return 1

  # (C) THE BASE IS AN AUTHORITATIVE COMMIT FROM THE API — NOT A LOCAL REF.
  # An earlier cut of this function asked `--not origin/$base`, trusting a LOCAL
  # remote-tracking ref. That was a FAIL-OPEN: a stale or divergent `origin/main`
  # makes everything reachable from IT count as "base content", so a commit the
  # review never saw is classified as base and the verdict carries. Reproduced by
  # pointing refs/remotes/origin/main at a branch containing an unreviewed file and
  # merging that branch: (C) came out empty and the predicate CARRIED. The local ref
  # was never fetched and never compared to the API, so it could not be trusted.
  # The authority is `.base.sha` from the API. Two things must then hold:
  #   - the head's SECOND PARENT (the base it actually merged) must be reachable
  #     from that authoritative base, so the base the head merged is base LINEAGE.
  #     This clause claims ONLY that much: it does not constrain the head's FIRST parent,
  #     and a head whose first parent is itself a merge IS carried (MEASURED with the real
  #     function — `current^1` was a merge, not the reviewed commit, and the verdict was
  #     CARRY). Which side is base-derived is settled by (A)/(B)/(C2)/(D), never by the
  #     shape of `current^1`.
  #     Reachability does NOT bound the head by the base TIP's tree, and the reason is
  #     NOT "lineage is safe" — that reason was FALSIFIED and is deleted: "it came from
  #     the base" does not make a blob something a review saw. A head whose only
  #     non-reviewed file exists in no reviewed commit and NOT in the base tip, but in a
  #     base ANCESTOR, IS carried (MEASURED twice, independently). What makes that SOUND is
  #     narrower: the reason is the LANE dimension, NOT the rendered patch. The rendered patch
  #     is EXPECTED to change here — that is why this arm exists at all, since §2982's
  #     byte-identity test cannot carry a base move that lands in a PR's hunk context (a
  #     reviewer MEASURED a head in this very class whose three-dot patch DIFFERS while all
  #     five clauses hold). The reason the carry is sound, stated as narrowly as it can be
  #     justified: (D) pins the head to the AUTOMATIC merge of `reviewed` with a base-LINEAGE
  #     commit, so the only content the head adds beyond that base lineage is `reviewed`'s own
  #     contribution — the commit the review approved.
  #     WHAT IS NOT CLAIMED HERE: no general theorem about landing — that is pinned by
  #     MEASUREMENT in §20/§21 of the suite. A merge-base IDENTITY **is** required, by clause
  #     (C3) below, and it is required precisely because an earlier revision asserted it in
  #     prose, a reviewer falsified the prose, the prose was deleted, and the invariant was left
  #     UNENFORCED — which is exactly how the round-23 leak existed. A head TREE exceeding
  #     `reviewed + base
  #     tip` is a DECLARED TOLERANCE, not a proof of safety, and §20 of the suite pins BOTH
  #     halves — including a fixture where the patch CHANGES and the head is still carried, so
  #     that a future tightening toward byte-identity reddens instead of landing; and
  #   - the object must be present locally, so the walk below is meaningful.
  # `.base.sha` is the CURRENT base tip, which is normally AHEAD of what the head merged,
  # so the check runs `--is-ancestor <head's second parent> <base_sha>`: the SECOND PARENT
  # must be an ancestor OF the authoritative base. The direction is NOT symmetric —
  # MEASURED on a real pair: `--is-ancestor p2 base_sha` is TRUE while
  # `--is-ancestor base_sha p2` is FALSE. Read the argument order, not the prose.
  base_sha="$(command gh api "repos/$REPO/pulls/$PR" --jq .base.sha 2>/dev/null || true)"
  # THE SHELL-FUNCTION VECTOR IS A CLASS, NOT THREE COMMANDS. An EXPORTED bash function is
  # inherited by `bash record-review.sh`, and it can intercept ANY external this script runs.
  # Reviewers PROVED three separate instances end-to-end, each minting a `clean` record for a
  # revision nobody reviewed: a function named `gh` nominating the base; one named `git`
  # forging `merge-tree`; and one named `head` reading the caller's `$current` through
  # DYNAMIC SCOPING to satisfy the tree equality in (D). `command` closes a name; it does not
  # close the class. This function therefore uses `command` for every external whose result
  # it DECIDES on: `gh`, `git`, and `head`. The rest of the script additionally routes
  # `openssl` (the diff hash and the prior-marker HMAC) through `command`, for the same
  # reason.
  # ⛔ THIS IS NOT A CLOSED CLASS, AND `command` DOES NOT CLOSE IT EITHER. `command` is a bash
  # BUILTIN, so a FUNCTION named `command` shadows it — a reviewer PROVED that exported
  # function minting a `clean` record for a head carrying unreviewed content, defeating every
  # `command` in this file at once; `builtin` is shadowable the same way, so `builtin command`
  # is no better. There is therefore NO shell-level way to guarantee an un-intercepted
  # external from inside the script, and no list of names can make one.
  # WHAT THE `command` PREFIXES ACTUALLY DO, stated without flattering them: `command X`
  # REMOVES the FUNCTION-named shadow (that is what the builtin does); what survives it is a
  # NON-function shadow — a binary earlier on PATH, or env/config redirection of the real
  # binary. The recorded instance that added `command gh` was ADVERSARIAL, not an operator
  # accident (a reviewer exported a `gh` function to mint a signed marker), so the prefixes
  # did not stop that actor and would not stop another. Nor do they make it true that "a
  # non-adversarial shadow cannot flip a verdict": only five names are qualified, while the
  # rest of the script's externals are invoked bare, and a shadowed one of THOSE decides a
  # verdict just as well. Defence in depth against a narrow accident, NOT a boundary.
  # THE REAL TRUST BOUNDARY: the environment this script runs in. EVERY external it invokes,
  # `$GATE_KEY` in this process's memory, and the review record itself are reachable by an
  # actor who controls it, and such an actor can write the record directly.
  # NO LIST OF THE REMAINING SURFACE IS GIVEN BELOW. Earlier versions enumerated "what is
  # left" and were wrong EVERY time, then contradicted themselves in the same paragraph by
  # naming names while denying the list. The surface is "everything the script runs", a list
  # of it re-stales, and so none is written.
  # `command gh` skips a shell FUNCTION named gh, which a reviewer used to nominate an
  # arbitrary local commit as the base and carry unreviewed content (a shim can emit only
  # 40-hex, so the shape check does not stop it).
  # RESIDUAL — the vectors NOT covered, NAMED rather than implied: a hostile BINARY earlier
  # on PATH, and ENV/CONFIG redirection of the real binary (GH_HOST, GH_CONFIG_DIR, or an
  # `http_unix_socket` in its config) — a reviewer demonstrated the last carrying unreviewed
  # content through the REAL gh. (A shell FUNCTION named gh is CLOSED, not residual: every
  # gh invocation in this script uses `command gh`. An earlier version of this note listed
  # the function under "NOT covered" AND claimed it closed in the same breath, and the claim
  # was untrue for the HEAD read, which a reviewer used to mint a signed
  # `@ <stale> diff=<live>` pair.)
  # WHY THOSE ARE DECLARED OUT RATHER THAN CLOSED: this predicate's threat surface is REPO
  # STATE — a stale ref, a replace ref, a grafts file, a lying remote-tracking ref: things
  # wrong by accident or residue, which is what the rails actually met. An actor who controls
  # THIS PROCESS'S ENVIRONMENT can already write the review record directly, since this same
  # script authors it, so no boundary is left to defend at that point; sanitising the env
  # would add machinery that closes one spelling while a config in the default location still
  # works. That is theatre, not a guard.
  # A MERGE DRIVER is a RESIDUAL, and it is declared rather than closed because closing it
  # would REVERSE A RECORDED DECISION. `git merge-tree` obeys .gitattributes, so (D) inherits
  # the repo's DECLARED merge semantics. tortoise#5373 deliberately sets `merge=union` on
  # config/ci-surfaces.yml and config/surface-manifest.yml (tortoise/.gitattributes, measured
  # 2026-09-26: 25 of 44 conflicted PRs conflicted on ci-surfaces.yml alone), and the SAME
  # file rejects a custom driver. A guard requiring the merged tree's BLOBS to be verbatim
  # copies of the inputs was proposed and MEASURED to REFUSE a legitimately union-merged
  # head — i.e. it would break the carry on exactly the two append-only registries most
  # lanes touch. So the fix would be worse than the vector. WHAT THE VECTOR ACTUALLY IS:
  # `merge=union` DOES emit a blob present in NEITHER input (measured), and a custom driver
  # (`.git/config`, or the equally local `.git/info/attributes`) can emit content from NO
  # ancestor at all. WHAT IT IS NOT, for an actor who can only PUSH A BRANCH: the built-in
  # drivers reachable from the WORKING TREE's attributes are text/union/binary, and, AS BUILT
  # IN, none can invent a LINE — union keeps both sides' lines, binary conflicts (rc refused),
  # text merges — so no built-in invents a LINE.`git merge-tree` reads attributes from the
  # WORKING TREE, not from the merged trees, so a PR's pushed .gitattributes takes effect once
  # its branch is checked out; and a config entry can SHADOW a built-in NAME
  # (`merge.union.driver`). The inventing case therefore needs a write to git's LOCAL
  # CONFIGURATION — the repo's .git/config or .git/info/attributes, OR the user's global config
  # — which is this script's OWN trust surface: a local writer can forge the review body this
  # function reads, so no boundary is left there to defend.
  # CONSEQUENCE OF THE WORKING-TREE SOURCE, stated because it is not obvious: the verdict is a
  # function of the CALLER's checkout, not only of the commits under review. MEASURED — for the
  # SAME (reviewed, current, base_sha), an UNTRACKED working-tree .gitattributes flips it: with
  # `f.txt merge=union` present the arm CARRYs (0), with it absent the merge conflicts and the
  # arm REFUSES (1). Absent attributes therefore fail CLOSED, which is the safe direction, but
  # anyone reading a verdict must know the checkout is an input to it.
  # ALSO NAMED: `.base.sha` is trusted as the authority and is NOT checked against
  # `.base.ref`, so a PR whose base has been REPOINTED to a branch carrying unreviewed content
  # has that content classified as base and the verdict carries (MEASURED with the real
  # function: a repointed base yields CARRY with the base branch's file in the head). That is a
  # SYMPTOM of the known base-blindness already filed for the
  # clean/clean-micro tiers — agent-infra#1362 — so it is NAMED here rather than re-filed as a
  # peer. §17 of the suite pins the union tolerance so a future blob-level "fix" reddens
  # instead of landing.
  # Reject everything that is not a 40-hex sha, exactly as the head fetch above does.
  # Empty/null/error-body already failed closed (measured), but any non-empty string
  # that happens to resolve as a LOCAL revision was accepted as "the authoritative
  # base" (a reviewer got `branch` through). A non-sha cannot come from the real API,
  # so this is hardening — but this function calls itself the trust boundary, and a
  # name is not an authority.
  case "$base_sha" in *[!0-9a-f]*|"") return 1 ;; esac
  [ "${#base_sha}" -eq 40 ] || return 1
  command git cat-file -e "$base_sha^{commit}" 2>/dev/null || return 1
  p2="$(command git rev-parse "$current^2" 2>/dev/null || true)"
  [ -n "$p2" ] || return 1
  command git merge-base --is-ancestor "$p2" "$base_sha" 2>/dev/null || return 1

  # (C3) THE MERGE BASE MUST **BE** p2 — not merely lie somewhere in the base's lineage.
  # THE LEAK THIS CLOSES, MEASURED with the real function: (C) admits ANY base-lineage
  # ancestor, so a head can carry commits NEWER than p2 that are still base lineage, and the
  # LANDING merge then takes that newer commit as its base — resurrecting content the base tip
  # has since DELETED into the base. A round-23 reviewer built exactly that head: it passes
  # (A), (B), (C), (C2) and (D), the verdict is CARRY, and `merge-tree(base_tip, current)`
  # carries a `leaked.env` that is in NO reviewed commit and NOT in the base tip.
  # THIS IS THE INVARIANT a previous revision ASSERTED IN PROSE AND THEN DELETED: it read "at
  # landing time the merge base of the head and the base tip is that same base-lineage commit".
  # A reviewer correctly falsified the sentence as written (it is false of the accepted set)
  # and it was removed — but removing the SENTENCE while leaving the CLAUSE out is what turned
  # a stated invariant into an unenforced one. The fix is the clause, not better prose.
  # AMBIGUITY FAILS CLOSED, and it is the EQUALITY line below that does it: a criss-cross
  # history makes `mb` a MULTI-LINE string, which can never equal the single-sha `p2`
  # (MEASURED: `--all` prints 2 bases, the verdict is REFUSE, and deleting the count line below
  # changes no verdict). The count line is RETAINED AS DEFENCE — one line, with no decider role
  # today — because it would matter if `mb` were ever narrowed to its first line.
  local mb=""
  mb="$(command git merge-base --all "$current" "$base_sha" 2>/dev/null)" || return 1
  [ "$(printf '%s\n' "$mb" | command grep -c .)" = 1 ] || return 1
  [ "$mb" = "$p2" ] || return 1

  # (C4) THE LANDING MERGE MUST NOT INTRODUCE CONTENT ABSENT FROM BOTH THE BASE TIP AND THE
  # REVIEWED COMMIT. (C3) fixes the landing merge BASE; it does not constrain the landing RESULT.
  #
  # THIS IS A BYTE-EXACT SEAM, NOT A SHELL PIPELINE, and the reason is measured. Rounds 26-30 each
  # found a DIFFERENT wrong-CARRY in the shell form — `core.quotePath` C-quoted path names,
  # `diff.relative` + the caller's cwd, the locale making `sort` exit 2 with empty stdout, the
  # `comm` exit status discarded inside `[ -z "$( ... )" ]`, and finally a shell FUNCTION named
  # `printf` shadowing the bash BUILTIN that produced `comm`'s inputs. Six of those eight ambient
  # inputs existed only because the comparison was expressed in the shell: command substitution
  # strips NULs and trailing newlines, `sort`/`comm` are locale- and status-sensitive, and path
  # names have to be quoted and unquoted. The comparison is therefore done in ONE place, in bytes,
  # where none of those can apply.
  #
  # It was differentially tested against the shell form it replaced before that form was deleted;
  # that comparison has no surviving artifact, so it is NOT cited here as evidence. The suite,
  # which RUNS, is the specification.
  # DELIBERATELY NO "fail closed on a binary blob" GUARD: the guard was measured to buy nothing —
  # a leak IS a line absent from tip + reviewed, so byte-exact line comparison already catches the
  # binary leak — and it produced the ONLY false refusal measured, on a legitimate binary union
  # carry that the shell form CARRIES. `--no-renames` also retires `diff.renames` as an input.
  #
  # FAIL CLOSED everywhere the model cannot represent the state: python3 absent (the heredoc cannot
  # run), `merge-tree` non-zero (a conflicted landing), a landing entry that is present but not a
  # readable blob (gitlink/tree/error), or an unreadable tip/reviewed entry. An entry ABSENT from
  # the landing is legitimate — the merge took a deletion.
  command python3 - "$reviewed" "$current" "$base_sha" <<'PYC4' || return 1
import os, subprocess, sys

reviewed, current, base_sha = sys.argv[1], sys.argv[2], sys.argv[3]
env = dict(os.environ)
# The replace-ref and grafts-file pins are NOT duplicated here, because the calling shell
# already exports them with `local -x` and python inherits them. Duplicating the pins was
# measured (round 31) to make both of their mutants INERT — a replace-ref pin is presence-tested
# rather than value-tested, and a nonexistent grafts file neutralises a graft exactly like an
# empty one — so the suite reported a benign "retirement" while two load-bearing fail-open
# guards went unproven. One pin, one owner.
env["LC_ALL"] = "C"


def git(bargs):
    p = subprocess.run([b"git"] + bargs, cwd=".", env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    return p.returncode, p.stdout


def exists(spec):
    return git([b"cat-file", b"-e", spec])[0] == 0


def read_blob(spec):
    rc, out = git([b"cat-file", b"blob", spec])
    return out if rc == 0 else None


def lines(b):
    if not b:
        return set()
    parts = b.split(b"\n")
    if parts and parts[-1] == b"":
        parts.pop()
    return set(parts)


rc, out = git([b"merge-tree", b"--write-tree", base_sha.encode(), current.encode()])
if rc != 0:
    sys.stderr.write("(C4) landing merge-tree failed (rc=%d)\n" % rc)
    sys.exit(1)
ltree = out.split(b"\n")[0]
if not ltree:
    sys.stderr.write("(C4) no landing tree\n")
    sys.exit(1)

# The path set: every path the base tip changed relative to the head's second parent. Read
# NUL-separated so no name is ever quoted, and no name can be split or dropped by a shell.
rc2, out = git([b"rev-parse", current.encode() + b"^2"])
if rc2 != 0:
    sys.stderr.write("(C4) no second parent\n")
    sys.exit(1)
p2 = out.strip()
rc3, out = git([b"-c", b"diff.relative=false",
                 b"diff", b"--name-only", b"-z", b"--no-renames", p2, base_sha.encode()])
if rc3 != 0:
    sys.stderr.write("(C4) path listing failed (rc=%d)\n" % rc3)
    sys.exit(1)
paths = [x for x in out.split(b"\0") if x]

for path in paths:
    lspec = ltree + b":" + path
    if not exists(lspec):
        continue
    # OID FIRST, and by TYPE-AGNOSTIC object id: the landing taking one side verbatim is
    # skipped on the OBJECT, not on the bytes. MEASURED (round 31) as two FALSE REFUSALS
    # otherwise: a base tip that turns file `x` into directory `x/` (the landing entry is a
    # TREE, `cat-file blob` fails) and a submodule pointer bump whose commit IS present
    # locally (a GITLINK). Both are pure base moves — the class this arm exists to carry —
    # and both were refused. `rev-parse` on a tree:path returns the entry's object id for a
    # blob, a tree and a gitlink alike, so this one comparison covers all three.
    def oid(spec):
        rc, out = git([b"rev-parse", b"--verify", b"--quiet", spec])
        return out.strip() if rc == 0 else None

    landing_oid = oid(lspec)
    tip_spec = base_sha.encode() + b":" + path
    rev_spec = reviewed.encode() + b":" + path
    if landing_oid is not None and (oid(tip_spec) == landing_oid
                                    or oid(rev_spec) == landing_oid):
        continue
    landing = read_blob(lspec)
    if landing is None:
        # NOT A READABLE BLOB. A TREE can legitimately hold content from BOTH inputs: when the
        # base tip and `reviewed` each turn the same file `x` into a directory, git merges the two
        # directories cleanly and the landing `x` is a THIRD tree unlike either input's. Refusing
        # that is a MEASURED FALSE REFUSAL (round 33) on a pure base-only move — the class this arm
        # exists to carry. So verify a landing tree's LEAVES by object id: every leaf that equals
        # the tip's or `reviewed`'s leaf at the same path is known-good, and anything matching
        # neither still FAILS CLOSED exactly as before. A gitlink (or anything else non-blob,
        # non-tree) also still fails closed: a gitlink taking a third value needs a conflict.
        # TWO ROUND-34 CORRECTIONS TO THIS BRANCH, both measured:
        #  (P0) `ls-tree … -- <path>` treats <path> as a PATHSPEC. `:magic` is a legal directory
        #       name, and pathspec MAGIC parses it away, so `ls-tree -- ':magic'` returns rc=0 with
        #       NO OUTPUT: the loop never ran, nothing was verified, and the head CARRIED where the
        #       previous code refused. `':x'` was worse — it enumerated the SIBLING `x` and
        #       validated the wrong tree. So the whole tree is listed and the leaves are SELECTED
        #       IN PYTHON. No pathspec is ever built from a path that came out of the repository.
        #  (P1) comparing object IDs here re-introduced the "a merged blob must be a verbatim copy
        #       of an input" guard that §17/§22 record as MEASURED AND REJECTED, because it refuses
        #       a LEGITIMATELY union-merged leaf — the append-only-registry class this arm exists to
        #       carry. The criterion is the blob arm's, applied at leaf level: LINE SETS.
        t_rc, t_out = git([b"cat-file", b"-t", lspec])
        if t_rc == 0 and t_out.strip() == b"tree":
            l_rc, l_out = git([b"ls-tree", b"-r", b"-z", b"--full-tree", ltree])
            if l_rc != 0:
                sys.stderr.write("(C4) landing tree listing failed: %r\n" % path)
                sys.exit(1)
            lprefix = path + b"/"
            for entry in l_out.split(b"\0"):
                if not entry:
                    continue
                hdr, sep, lpath = entry.partition(b"\t")
                fields = hdr.split()
                if sep != b"\t" or len(fields) < 3:
                    sys.stderr.write("(C4) unparseable landing entry: %r\n" % entry[:80])
                    sys.exit(1)
                if lpath != path and not lpath.startswith(lprefix):
                    continue
                loid = fields[2]
                lspec2 = ltree + b":" + lpath
                tip_l = base_sha.encode() + b":" + lpath
                rev_l = reviewed.encode() + b":" + lpath
                if oid(tip_l) == loid or oid(rev_l) == loid:
                    continue
                lb = read_blob(lspec2)
                if lb is None:
                    sys.stderr.write("(C4) landing leaf unreadable and unlike both inputs: %r\n" % lpath)
                    sys.exit(1)
                known = set()
                for spec in (tip_l, rev_l):
                    if exists(spec):
                        b = read_blob(spec)
                        if b is None:
                            sys.stderr.write("(C4) leaf unreadable: %r\n" % lpath)
                            sys.exit(1)
                        known |= lines(b)
                # REACHABILITY BOUND (rounds 35-36, MEASURED — state it, do not imply a guard):
                # the LEAK CHECK below fires ZERO times across the suite's 138 assertions, and
                # replacing this TREE-VERIFICATION BODY alone (the l_rc...continue block, keeping
                # the non-tree fallthrough) leaves the suite GREEN at the same count — so the leak
                # comparison is DEFENCE IN DEPTH over the declared residual, not a live guard.
                # Do NOT read that as "this branch is inert": the FALLTHROUGH REFUSAL at the end
                # of this else-branch IS load-bearing and is pinned by section 29b's NOSKIP mutant
                # — neutering the WHOLE non-blob branch reddens "mutation NOSKIP is NOT caught on
                # the gitlink fixture". The mechanism: a leak needs a LINE absent from both the
                # base tip and `reviewed`, and the only hermetic shape is a union merge driver
                # re-admitting a line the tip DELETED (the section 22 residual), which lives at a
                # path the tip CHANGED, where the BLOB ARM decides it. The leaf comparison is KEPT
                # because a landing tree whose leaves come from neither input is precisely the
                # class that must never carry if it becomes reachable, and it costs one
                # comparison when it is not.
                lnew = lines(lb) - known
                if lnew:
                    sys.stderr.write("(C4) LEAK %r -> %r\n" % (lpath, sorted(lnew)[:5]))
                    sys.exit(1)
            continue
        sys.stderr.write("(C4) landing entry unreadable and unlike both inputs: %r\n" % path)
        sys.exit(1)
    tip = rev = None
    for spec, which in ((tip_spec, "tip"), (rev_spec, "reviewed")):
        if not exists(spec):
            continue
        blob = read_blob(spec)
        if blob is None:
            sys.stderr.write("(C4) %s entry unreadable: %r\n" % (which, path))
            sys.exit(1)
        if which == "tip":
            tip = blob
        else:
            rev = blob
    new_lines = lines(landing) - (lines(tip or b"") | lines(rev or b""))
    if new_lines:
        sys.stderr.write("(C4) LEAK %r -> %r\n" % (path, sorted(new_lines)[:5]))
        sys.exit(1)

sys.exit(0)
PYC4

  # (C2) NO LANE COMMITS IN BETWEEN: every intervening commit not reachable from the
  # AUTHORITATIVE base must be a MERGE. A single non-merge commit is lane work and a
  # fresh review is owed (that is the #5421 counter-example: cfe2bad0afaa is one).
  # The walk's STATUS IS CHECKED EXPLICITLY: a failed walk prints nothing to stdout,
  # and "nothing" here would read as "no lane commits" — the fail-open direction.
  extra="$(command git rev-list --no-merges "$reviewed..$current" --not "$base_sha" 2>/dev/null)" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  [ -z "$extra" ] || return 1

  # (D) NO CONFLICT RESOLUTION — the clause that makes the arm sound. (C2) alone is
  # NOT sufficient: a lane can merge the base LOCALLY with conflict resolutions, and
  # that merge is indistinguishable from a clean one by commit shape. So recompute
  # the merge and compare TREES rather than patch text.
  # rc IS CHECKED, AND THIS IS LOAD-BEARING: `git merge-tree --write-tree` PRINTS A
  # TREE OID ON LINE 1 EVEN WHEN IT CONFLICTS (exit 1). An earlier cut discarded the
  # status and piped through `head -1`, so a conflicted merge looked like a
  # successful merge-tree and the guard rested on the tree inequality alone — which
  # contradicts this function's own fail-closed claim and was refuted by a reviewer
  # reproduction. Requiring rc=0 restores "conflict => refuse" as a real gate.
  merged="$(command git merge-tree --write-tree "$reviewed" "$p2" 2>/dev/null)" || mrc=$?
  [ "$mrc" -eq 0 ] || return 1
  # `command head`, not bare head: an EXPORTED shell function named head can read the
  # caller's `$current` (bash `local` is DYNAMICALLY scoped) and hand back the head's own
  # tree, satisfying the equality below. A reviewer PROVED it against the real script:
  # honest rc=3 with no record, hijacked rc=0 with a `clean` record minted at the live head.
  merged="$(printf '%s' "$merged" | command head -1)"
  [ -n "$merged" ] || return 1
  ctree="$(command git rev-parse "$current^{tree}" 2>/dev/null || true)"
  [ -n "$ctree" ] || return 1
  [ "$merged" = "$ctree" ] || return 1
  return 0
}

# ── Clause (E) of the carry contract (#1575): THE TARGET HEAD IS NOT MEASURABLY RED ──
# A carry re-binds a signed verdict to a NEW head. Clauses (A)-(D) and the #2982
# byte-identity test are all COMMIT-TOPOLOGY tests: they prove the LANE's artifact is
# unchanged, and they are right about that. But a base-only move IS a change to the
# tree the verdict describes, so the attestation can say `clean` about a head whose own
# checks are failing. MEASURED three times in one session: tortoise #4823 (the carry
# laundered a refusal — re-bound FROM the head that had just been refused), #5395
# (re-stamped onto two deterministic failures sitting on BOTH sides of the stamp), and
# #5292 (the failing test measured five minutes after the stamp, same head, same tree).
#
# POLARITY — the rail's own rule (#1399 / tortoise #4877), and it is deliberately NOT
# "any failure". Group by (app.slug, check name) and keep each group's NEWEST attempt
# by `id`; a group is RED when its NEWEST attempt's conclusion is outside the
# green/non-red allow-list — INCLUDING a conclusion GitHub has not documented and a
# null one. An UNGROUPED `any failure` would refuse a head an older
# attempt of which was re-run green, which this fleet produces routinely (one job held
# 10 attempts carrying both `failure` and `success`), and a guard that fires on green
# heads gets deleted rather than fixed.
#
# NOT RED, AT THIS STAGE, IS NOT A CERTIFICATE OF HEALTH: an absent, empty or in-flight
# surface is simply not shown red, which is the pre-existing state of every carry. This
# clause can only ADD a refusal; it can never authorise one.
#
# THE SURFACE EXCLUDES THIS FLEET'S OWN EVIDENCE GATE (#1590 review). `ai-review-gate`
# sits on the PR HEAD and goes red BECAUSE the evidence is stale — the very state the
# carry exists to remedy. Counting it refuses `lane_dimension_carry` BY CONSTRUCTION,
# since that arm fires precisely when the rendered diff moved and the gate's rule (b)
# can therefore no longer match. #6213 measured exactly this transition: the gate went
# SUCCESS -> FAILURE seven seconds after the rail moved the head. The veto asks whether
# the TREE is independently red, so a red the carry itself explains is not evidence.
# Override with RECORD_REVIEW_RED_EXCLUDE (space-separated check names).
#
# KNOWN, DELIBERATE DIVERGENCE from the rail's version of this rule: the rail also reads
# legacy commit `/status`. This reads `/check-runs` only, so a red posted as a legacy
# status is invisible here. Stated rather than implied — on agent-infra's own head
# `statuses == 0`, and a false claim of parity is worse than a named gap.
RECORD_REVIEW_RED_EXCLUDE="${RECORD_REVIEW_RED_EXCLUDE-ai-review-gate ai-review-gate-tests}"
target_head_red() { # <head> -> 0 = measurably red, 1 = not shown red
  local raw
  raw="$(command gh api "repos/$REPO/commits/$1/check-runs?per_page=100&filter=all" \
           --paginate \
           --jq '.check_runs[] | "\(.app.slug // "?")|\(.name)|\(.id)|\(.status)|\(.conclusion // "null")"' 2>/dev/null || true)"
  [ -n "$raw" ] || return 1
  printf '%s\n' "$raw" | awk -F'|' -v excl="$RECORD_REVIEW_RED_EXCLUDE" '
    { # A literal pipe inside a check name (a matrix job named `shard 1 | slow`) shifts
      # every later field, so the row cannot be grouped. DISCARDING it is the #1353
      # fail-open AGAIN: the row would vanish, its group never exists, and the surface
      # reads GREEN. The rail parses JSON and counts such a check by its REAL
      # conclusion, which is exactly what this code cannot read here — so this is a
      # deliberate fail-CLOSED over-block relative to the rail, NOT parity with it. An
      # input we cannot positively read as non-red is RED; the allow-list polarity
      # decides unknown input rather than shrugging at it. Say so instead of dropping mute.
      if (NF != 5) {
        print "record-review: ⚠️ unparseable check-run row (a pipe in app.slug or name) — treating the target head as RED rather than reading it green (#1575)" > "/dev/stderr"
        red = 1; next
      }
      k = $1 "|" $2
      if (!(k in id) || $3 + 0 > id[k]) { id[k] = $3 + 0; st[k] = $4; c[k] = $5 } }
    END {
      n = split(excl, ex, " ")
      for (i = 1; i <= n; i++) if (ex[i] != "") skip[ex[i]] = 1
      for (k in st) {
        if (skip[substr(k, index(k, "|") + 1)]) continue
        # IN FLIGHT means a status the API NAMES as in flight. Every other status —
        # including one whose spelling this code has never seen — is judged by its
        # conclusion under the allow-list, so an unrecognised status with a null
        # conclusion is RED. Gating on "no conclusion" instead is exactly the #1353
        # fail-open the rail closed by switching to a named in-flight set: any
        # spelling it had not seen read as pending, and the surface read GREEN.
        if (st[k] != "completed" && st[k] ~ /^(queued|in_progress|waiting|requested|pending)$/) continue
        if (c[k] != "success" && c[k] != "neutral" && c[k] != "skipped" &&
            c[k] != "cancelled" && c[k] != "stale") { red = 1; break }
      }
      exit(red ? 0 : 1)
    }'
}

# #2982 — carry-forward arm: when the head has moved but the PR already carries
# signed evidence for EXACTLY this diff (a marker whose diff= equals the live
# diff hash), the head moved without the reviewed artifact changing (a
# merge-only update). Re-record against the CURRENT head with that diff hash,
# which is precisely what the gate needs — instead of refusing and deadlocking.
# When no such marker exists the diff is genuinely unreviewed → still refuse.
if [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
  CURRENT_HEAD="$(command gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null || true)"
  # gh api prints 4xx error bodies to stdout — only a well-formed 40-hex
  # sha counts as a successful fetch; anything else fails open.
  if ! [[ "$CURRENT_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
    # #784: the head could NOT be confirmed, so nothing shows that the caller's
    # sha and this diff were ever observed together. Binding them would mint
    # `@ <sha> diff=<live_diff>` on an UNVERIFIED sha — and a diff-equality
    # acceptance rule takes that at face value, so a transient gh/API failure
    # (403 rate-limit, 5xx, expired token) would launder any sha into a
    # gate-accepted diff binding. Degrade to a legacy sha-only marker instead:
    # the gate's strict sha path then governs. This keeps the documented
    # fail-open (a transient failure still allows a record) WITHOUT letting that
    # failure become a PASS.
    DIFF_HASH=""
    echo "⚠️ stale-sha guard: could not fetch the current head of $REPO#$PR (gh/API failure?) — continuing fail-open and WITHOUT a diff binding (#784); double-check the sha before relying on the gate" >&2
  elif [ "$CURRENT_HEAD" != "$SHA" ]; then
    echo "stale-sha guard: provided sha $SHA is NOT the current PR head $CURRENT_HEAD" >&2
    # Carry-forward arm (#2982): does the PR already carry evidence for this
    # exact diff? Only then is the head-move provably a no-op to the artifact.
    PRIOR_DIFF=""
    if [ -n "$DIFF_HASH" ]; then
      PRIOR_BODY="$(command gh api "repos/$REPO/pulls/$PR" --jq .body 2>/dev/null || true)"
      [ "$PRIOR_BODY" = "null" ] && PRIOR_BODY=""
      # The prior marker is evidence ONLY if it is AUTHENTIC. The PR body is
      # attacker-writable, so matching `sig=[0-9a-f]{64}` is not enough: a forged
      # `sig=<64 zeros>` line would satisfy the shape, be carried forward, and be
      # RE-SIGNED with the real key — minting a genuine signature at the current
      # head for a diff nobody reviewed, which the gate cannot detect because the
      # producer IS the signer (#784). So verify the HMAC over the marker text.
      # VERDICT is pinned in the pattern too, so a prior clean-micro attestation
      # cannot authorize a full clean record.
      # #1362 D1 — BACKWARD COMPATIBILITY. A prior marker may carry EITHER the
      # new NORMALIZED hash or the pre-#1362 RAW hash. Without the raw arm every
      # marker minted before this change stops carrying and the required check
      # reddens fleet-wide (the #3076 shape). Both are hashes of the CURRENT
      # diff (same fetch), so either match proves the reviewed artifact is
      # unchanged; the re-record below then UPGRADES the binding to the
      # normalized hash. The alternation stays inside the ONE grep so the
      # documented "first matching line governs" ordering is preserved.
      PRIOR_DIFF_ALT="$( [ -n "$LEGACY_DIFF_HASH" ] && [ "$LEGACY_DIFF_HASH" != "$DIFF_HASH" ] && printf '(%s|%s)' "$DIFF_HASH" "$LEGACY_DIFF_HASH" || printf '%s' "$DIFF_HASH" )"
      PRIOR_LINE="$(grep -m1 -E "^review recorded: reviews/${PR}\.json verdict=${VERDICT} @ [0-9a-f]{40} diff=${PRIOR_DIFF_ALT} \(.*\) sig=[0-9a-f]{64}$" <<<"$PRIOR_BODY" || true)"
      if [ -n "$PRIOR_LINE" ] && [ -n "$GATE_KEY" ]; then
        PRIOR_TEXT="${PRIOR_LINE% sig=*}"
        PRIOR_SIG="${PRIOR_LINE##* sig=}"
        PRIOR_EXPECT="$(printf '%s' "$PRIOR_TEXT" | command openssl dgst -sha256 -hmac "$GATE_KEY" 2>/dev/null | awk '{print $NF}' || true)"
        if [ -n "$PRIOR_EXPECT" ] && [ "$PRIOR_SIG" = "$PRIOR_EXPECT" ]; then
          PRIOR_DIFF="$DIFF_HASH"
        else
          echo "⚠️ #784: found prior evidence in the PR body with the right shape but a BAD SIGNATURE — ignoring it (the PR body is not a trust boundary)" >&2
        fi
      fi
    fi
    # Which carry arm applies? Decided FIRST so that clause (E) can veto a carry that
    # neither arm's own conditions can see: both arms prove the LANE's artifact is
    # unchanged, and neither says anything about the health of the head it binds to.
    CARRY_ARM=""
    if [ -n "$PRIOR_DIFF" ]; then
      CARRY_ARM="diff"
    elif [ "$FORCE_STALE" -ne 1 ] && lane_dimension_carry "$SHA" "$CURRENT_HEAD"; then
      CARRY_ARM="lane"
    fi
    if [ -n "$CARRY_ARM" ]; then
      # (E) (#1575) — the veto. Refuse BEFORE printing either arm's success line and
      # before re-binding SHA, so a red target never produces a signed `clean`.
      if target_head_red "$CURRENT_HEAD"; then
        echo "⛔ (#1575 clause E) refusing the carry onto ${CURRENT_HEAD:0:12}… — the TARGET HEAD IS MEASURABLY RED." >&2
        echo "   A base-only move is still a change to the tree the verdict describes, so re-binding '$VERDICT' to it would put a SIGNED 'clean' on a head whose own checks are failing — an attestation that records a red tree as reviewed-green, and one the merge gate cannot see once the record outlives the run (#4823, #5395, #5292)." >&2
        echo "   The LANE's artifact IS unchanged — that is what the carry proved. Only the head's health is unknown or bad. Re-review at ${CURRENT_HEAD:0:12}…, or re-run the failing checks and re-record." >&2
        exit 3
      fi
      if [ "$CARRY_ARM" = "diff" ]; then
        echo "#2982 carry-forward: head moved ${SHA:0:12}… → ${CURRENT_HEAD:0:12}…, but the reviewed diff is unchanged (diff=${DIFF_HASH}) and already carries signed evidence — recording against the CURRENT head" >&2
      else
        # The rendered patch moved (a base merge), but the LANE's artifact is
        # provably unchanged: the head only moved forward, no lane commit is in
        # between, and a clean re-merge of (reviewed, its base parent) reproduces
        # the head's tree exactly. Re-record against the CURRENT head, exactly as
        # the arm above does — the binding is to the head that will merge.
        echo "#6072/#6213/#4823 lane-dimension carry: head moved ${SHA:0:12}… → ${CURRENT_HEAD:0:12}…, the rendered diff changed but the LANE's commits are provably identical (forward move; no non-base NON-MERGE commit in between — an intervening merge is permitted, which is why the tree check below is load-bearing; the head's tree is exactly a clean merge of reviewed and its base parent) — recording against the CURRENT head" >&2
      fi
      SHA="$CURRENT_HEAD"
    elif [ "$FORCE_STALE" -ne 1 ]; then
      echo "   no prior evidence for this PR's current diff (diff=${DIFF_HASH:-unavailable}) — the reviewed artifact cannot be shown unchanged" >&2
      echo "refusing to record stale sha $SHA for $REPO#$PR — re-record with the current head ${CURRENT_HEAD:0:12}… (or pass --force-stale to override)" >&2
      exit 3
    else
      # #784: a stale sha's diff CANNOT be shown to be the current diff — by
      # construction the two were never observed together. Emitting `diff=` here
      # would mint `@ <stale_sha> diff=<live_diff>`, a pair that never coexisted,
      # and acceptance rule (b) (diff-equality alone) would ACCEPT it — attesting
      # to a revision nobody can show was reviewed. So drop the diff-binding: the
      # marker degrades to legacy sha-only, rule (b) cannot fire, and the gate's
      # strict sha path rejects it. That refusal is the honest outcome for a
      # recorded-but-unprovable revision, and --force-stale stays usable for its
      # intended local/emergency purpose.
      DIFF_HASH=""
      echo "⚠️ --force-stale passed: recording stale sha $SHA anyway, with NO diff binding (#784 — a stale sha's diff cannot be shown unchanged) — the ai-review-gate will keep rejecting until re-recorded at the current head" >&2
    fi
  fi
fi

# ── tortoise#7391 — a FRESH `clean` record must name a review artifact ───────────
# This is the branch the defect lived on. CARRY_ARM is set ONLY when a verified
# carry re-bound the verdict to the live head, so an empty CARRY_ARM means this
# invocation is minting a NEW `clean` attestation at the head it names — the
# case that, before this guard, recorded unconditionally with no evidence
# question asked on any path. NOTE this runs OUTSIDE the REPO/gh block above,
# so an invocation that cannot reach GitHub at all (no repo, missing gh) is
# refused rather than silently un-asked: verification is the point.
if [ "$VERDICT" = "clean" ] && [ -z "$CARRY_ARM" ]; then
  if [ -z "$EVIDENCE" ]; then
    echo "⛔ tortoise#7391: refusing to mint a 'clean' record for ${SHA:0:12}… with NO review evidence." >&2
    echo "   A 'clean' verdict is a full-review attestation, and this invocation is a FRESH one: it is not a carry (no prior signed marker was verified for this diff), so nothing here shows a review happened." >&2
    echo "   Naming the PR's CURRENT head is not evidence — that is precisely the invocation that recorded an unreviewed diff before this guard existed (tortoise#7391; tortoise#3549 merged on exactly such a record while every review comment on it said NOT CLEAN)." >&2
    echo "   → Run the review, then name its artifact: record-review.sh $PR $SHA clean ${REPO:-<owner/repo>} --evidence <comment:<id> | review:<id> | review-comment:<id> | <its URL>>" >&2
    echo "   → If a verdict is ALREADY recorded at an earlier head and only the base moved, land via the rail (scripts/atomic-land.sh): it carries the verified record and needs no --evidence." >&2
    exit 3
  fi
  if ! verify_review_evidence "$EVIDENCE" "$SHA" >/dev/null; then
    echo "⛔ tortoise#7391: refusing to mint a 'clean' record for ${SHA:0:12}… — the named review evidence could not be verified (reason above)." >&2
    exit 3
  fi
  EVIDENCE_VERIFIED="$EVIDENCE"
  echo "✅ tortoise#7391 review evidence verified: $EVIDENCE" >&2
fi

# ── Clean-micro tier guard (#513) ──────────────────────────────────────────
# clean-micro certifies the MICRO process: the linked same-repo issue must
# carry the complexity:micro label at record time. Standard/complex/complexity
# issues are never recorded clean-micro (run the code-review skill and record
# clean instead). Clean verdicts skip this guard entirely (zero extra gh
# calls). Arms:
#   (a) ≥1 same-repo closing ref carries complexity:micro and none is
#       non-micro → allow.
#   (b) ANY same-repo closing ref carries a complexity:* label ≠ micro →
#       REFUSE exit 4, NO write (qualified + legacy keys untouched; a
#       pre-existing valid record survives).
#   (c) undeterminable — repo-less / gh missing / body unreadable / no
#       closing ref / only cross-repo refs / label fetch failed / fetched
#       labels carry no complexity:* → loud warning + record proceeds
#       (fail-open: a transient gh/API failure must not block a legitimate
#       record; the warning names the unverified tier).
# Ref collection keeps GITHUB PARITY (#1012 r2): the guard unions the
# positional scan with a WORD-BOUNDARY-ANCHORED CLOSING_KW scan, because GitHub
# auto-closes a mid-sentence ref — a body like "Closes #100" + "This also
# closes #42" closes complex #42 on merge and must never record clean-micro off
# micro #100 alone. Refusal is the fail-closed direction, so the union widens
# the bind without widening the fail-open arms. The `\b` on the parity class is
# the OTHER direction: an unanchored class matches inside English words, turning
# `The prefix #42 is unrelated.` into a refusal GitHub itself would never make
# (#1012 r3).
if [ "$VERDICT" = "clean-micro" ]; then
  if [ -z "$REPO" ] || ! command -v gh >/dev/null 2>&1; then
    echo "⚠️ clean-micro tier guard: repo undetectable or gh missing — tier attestation UNVERIFIED (record proceeds; a non-micro linked issue should never be recorded clean-micro)" >&2
  else
    BODY="$(command gh api "repos/$REPO/pulls/$PR" --jq .body 2>/dev/null || true)"
    [ "$BODY" = "null" ] && BODY=""
    if [ -z "$BODY" ]; then
      echo "⚠️ clean-micro tier guard: could not read the PR body of $REPO#$PR (gh/API failure or empty body?) — tier attestation UNVERIFIED (record proceeds)" >&2
    else
      # Collect same-repo closing refs (dedupe via awk; preserve order).
      # GITHUB PARITY (#1012 r2): the POSITIONAL scan alone misses a
      # mid-sentence "This also closes #42" that GitHub WILL auto-close on
      # merge, so the guard unions it with a keyword-class scan. Refusing on a
      # ref either scan finds is fail-CLOSED. The parity scan is
      # WORD-BOUNDARY-ANCHORED (#1012 r3): `\b` before the class keeps ordinary
      # prose ("prefix", "discloses", "unresolved") from being read as a
      # keyword and refused, which would be a FALSE refusal — GitHub requires a
      # word boundary the unanchored scan did not.
      REFS="$({ closing_issue_refs "$BODY"; closing_issue_refs "$BODY" "\b${CLOSING_KW}"; } | awk -F'#' 'tolower($1) == tolower("'"$REPO"'") { seen[$0]++; if (seen[$0] == 1) print }')"
      if [ -z "$REFS" ]; then
        echo "⚠️ clean-micro tier guard: no same-repo closing-issue ref found in the PR body of $REPO#$PR — tier attestation UNVERIFIED (record proceeds; body refs: $(printf '%s' "$BODY" | grep -oE '(fix(es|ed)?|close(s|d)?|resolve(s|d)?)[[:space:]]*[^[:space:],;)]*' | command head -c 200 || true))" >&2
      else
        # Per-ref label fetch. A fetch failure marks THAT ref undeterminable —
        # never refuse on a failed fetch (mirrors the stale-sha fail-open).
        REFUSED=""
        MICRO_SEEN=""
        while IFS= read -r ref; do
          [ -z "$ref" ] && continue
          num="${ref##*#}"
          LABELS="$(command gh api "repos/$REPO/issues/$num/labels" --jq '.[].name' 2>/dev/null || true)"
          # A failed/filtered fetch yields nothing — undeterminable ref.
          if [ -z "$LABELS" ]; then
            echo "⚠️ clean-micro tier guard: could not fetch labels of $ref — that ref is undeterminable (record proceeds unless another ref is non-micro)" >&2
            continue
          fi
          if grep -q '^complexity:micro$' <<<"$LABELS"; then
            MICRO_SEEN=1
            continue
          fi
          if grep -qE '^complexity:' <<<"$LABELS"; then
            OFFENDING_LABEL="$(printf '%s\n' "$LABELS" | grep -E '^complexity:' | command head -1)"
            REFUSED=1
            echo "❌ clean-micro tier guard: $REPO#$PR closes $ref, whose complexity label is \"$OFFENDING_LABEL\" — clean-micro certifies the MICRO process only and is REFUSED for a non-micro linked issue." >&2
            echo "   → Run the code-review skill on the current head and record clean:" >&2
            echo "   →   record-review.sh $PR <head-sha> clean $REPO --evidence <artifact>" >&2
            echo "   →   (<artifact> = the review comment the skill posted, e.g. comment:<id>; see the --evidence rules above.)" >&2
            echo "   → If the issue's tier is genuinely micro, correct its label (issue-creation: relabel complexity:micro), then re-record clean-micro." >&2
            break
          fi
          # Labels fetched but no complexity:* label → undeterminable ref.
          echo "⚠️ clean-micro tier guard: $ref carries no complexity:* label — that ref is undeterminable (record proceeds unless another ref is non-micro)" >&2
        done <<EOF
$REFS
EOF
        if [ -n "$REFUSED" ]; then
          exit 4
        fi
        if [ -z "$MICRO_SEEN" ]; then
          echo "⚠️ clean-micro tier guard: no same-repo closing ref resolved to complexity:micro — tier attestation UNVERIFIED (record proceeds)" >&2
        fi
      fi
    fi
  fi
fi

# ── clean-low content-shape guard (#1348) ─────────────────────────────────
# clean-low attests that EVERY changed path of the recorded revision is prose
# or a stylesheet. There is no second evidence behind the verdict: the shape IS
# the attestation. So every arm here is FAIL-CLOSED — an unverifiable shape
# must never read as "certified Low", because that would be a vacuous PASS at
# the last gate before main (the #1319 family: what the gate does when evidence
# is ABSENT rather than negative). Exit 4, no record written, no marker posted.
#
# The stale-sha guard above deliberately fails OPEN on a transient gh failure (a
# legitimate record must not be stranded). This guard cannot inherit that
# posture, so it re-reads the head itself and refuses if it cannot confirm it.
#
# The diff is read from compare/<base>...<sha>, NOT pulls/<n>/files: the latter
# always describes the PR's CURRENT head, so a push landing between the fetch and
# the write would let a docs diff be certified while code had already arrived.
# A compare against an EXPLICIT sha has no such window — the endpoint is
# sha-addressable, so the attestation describes exactly $SHA.
if [ "$VERDICT" = "clean-low" ]; then
  if [ -z "$REPO" ] || ! command -v gh >/dev/null 2>&1; then
    echo "❌ clean-low content-shape guard: repo undetectable or gh missing — clean-low certifies the DIFF's content shape, which cannot be read without gh and a repo. Refusing (exit 4, no record)." >&2
    exit 4
  fi
  # One read for head + base + the authoritative changed-file count (the count
  # is GitHub's own, so a truncated or forged file list cannot pass unnoticed).
  META="$(command gh api "repos/$REPO/pulls/$PR" --jq '[(.head.sha), (.base.sha), ((.changed_files // 0) | tostring)] | @tsv' 2>/dev/null || true)"
  META_HEAD="$(printf '%s' "$META" | cut -f1)"
  META_BASE="$(printf '%s' "$META" | cut -f2)"
  META_COUNT="$(printf '%s' "$META" | cut -f3)"
  if ! [[ "$META_HEAD" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$META_BASE" =~ ^[0-9a-f]{40}$ ]] || ! [[ "$META_COUNT" =~ ^[1-9][0-9]*$ ]]; then
    echo "❌ clean-low content-shape guard: could not read the head/base/changed-file count of $REPO#$PR (gh or API failure?) — the shape is unverifiable, so the Low attestation is refused (exit 4, no record)." >&2
    exit 4
  fi
  if [ "$META_HEAD" != "$SHA" ]; then
    echo "❌ clean-low content-shape guard: recorded sha $SHA is not the current head $META_HEAD of $REPO#$PR — the two revisions can differ in shape, so certifying Low for the recorded one would describe the wrong diff. Refusing (exit 4, no record); re-record at the current head without --force-stale." >&2
    exit 4
  fi
  # One read returns BOTH the merge base and the rows. `.merge_base_commit.sha`
  # is the commit the three-dot diff is taken FROM — i.e. the sha that actually
  # identifies the certified CONTENT, which `$META_BASE` (the base branch's TIP)
  # does not: a base that merely ADVANCES leaves the merge base untouched and
  # the certified diff identical, while a base that is REPOINTED does not. The
  # record pins the merge base, the consumer re-derives it, and the gate blocks
  # only when the content can actually differ. Pinning the tip instead would
  # false-block every clean-low PR on the next unrelated merge to main.
  CMP="$(command gh api "repos/$REPO/compare/$META_BASE...$SHA" --jq '.merge_base_commit.sha as $mb | "mb\t\($mb)", (.files[]? | [.status, .filename, (.previous_filename // "")] | @tsv)' 2>/dev/null || true)"
  MB="$(printf '%s\n' "$CMP" | command head -1 | cut -f2)"
  RAW="$(printf '%s\n' "$CMP" | command tail -n +2)"
  if ! [[ "$MB" =~ ^[0-9a-f]{40}$ ]]; then
    # Empty diff, a compare/API failure, a fork head not reachable from the
    # base repo (compare 404s there), or a response with no merge base. All are
    # fail-CLOSED: a fork PR is a predictable FALSE BLOCK, recorded in the #1348
    # plan so it is not later re-diagnosed as a bug.
    echo "❌ clean-low content-shape guard: read no merge base for $REPO#$PR at $SHA (empty diff, API failure, or an unreachable fork head) — an unverifiable shape cannot be certified Low. Refusing (exit 4, no record)." >&2
    exit 4
  fi
  if [ -z "$RAW" ]; then
    echo "❌ clean-low content-shape guard: no changed files under merge base ${MB:0:12}… for $REPO#$PR — refusing (exit 4, no record)." >&2
    exit 4
  fi
  if ! ROWS="$(clean_low_rows <<< "$RAW")"; then
    echo "❌ clean-low content-shape guard: malformed diff row for $REPO#$PR (framing, unknown status enum, a rename without its old path, or a copy) — refusing (exit 4, no record)." >&2
    exit 4
  fi
  if ! clean_low_shape_ok "$ROWS" "$META_COUNT"; then
    echo "❌ clean-low content-shape guard: $REPO#$PR at ${SHA:0:12}… is NOT content-only. clean-low certifies that every changed path is prose or a stylesheet (docs/ + md|markdown|txt|rst|adoc|css|scss, or a named root-level prose file) — no program code, no config file, no enforcement input. Refusing (exit 4, no record)." >&2
    echo "   Changed paths:" >&2
    printf '%s\n' "$ROWS" | LC_ALL=C awk -F '\t' '{ print "     " $1 " " $2 }' >&2
    echo "   → Run the code-review skill on the current head, then record clean:" >&2
    echo "   →   record-review.sh $PR $SHA clean $REPO --evidence <artifact>" >&2
    echo "   →   (<artifact> = the review comment the skill posted, e.g. comment:<id>; see the --evidence rules above.)" >&2
    echo "   → A docs change that ALSO adds a non-prose file (an image, a data or" >&2
    echo "     config file under docs/, .html, .mdx) is refused the same way: only" >&2
    echo "     the prose/stylesheet extensions are in class, so it has no Low verdict." >&2
    exit 4
  fi
  # The verdict is new, and a REMOTE ai-review-gate required check that still
  # regex-matches `verdict=clean(-micro)?` will keep failing on this marker.
  # Same posture as the missing-HMAC-key warning below: say it loudly at record
  # time rather than let the agent discover it as a red required check and fall
  # back to recording a false `clean`. The record and the LOCAL merge gate are
  # unaffected. Widen the consumer at daniel-ospina/tortoise#4755.
  echo "ℹ️ clean-low recorded. A remote ai-review-gate still matching 'verdict=clean(-micro)?' will reject this marker until the consumer is widened (tortoise#4755) — the record and the local merge gate are unaffected." >&2
fi

DIR="$HOME/.pi/agent/reviews"
mkdir -p "$DIR"
# #426: registry key is repo-qualified when the repo is known — PR numbers
# collide across repos (a stale DMeer #441 record in 441.json blocked
# agent-infra #441's merge). Legacy <pr>.json stays for repo-less records.
if [ -n "$REPO" ]; then
  FILE="$DIR/${REPO%/*}-${REPO#*/}-$PR.json"
  LEGACY="$DIR/$PR.json"
else
  FILE="$DIR/$PR.json"
  LEGACY=""
fi
TMP="$FILE.tmp"
# #1348 — pin the MERGE BASE the clean-low guard certified. The attestation is
# a function of the three-dot diff `compare/<base>...<head>`, whose CONTENT is
# identified by `merge_base_commit.sha` — not by the base branch's tip. Pinning
# the tip would be both wrong (a benign advance of the base branch moves the tip
# while the certified diff is identical, so every clean-low record would expire
# on the next unrelated merge to main) and weaker (the tip does not identify the
# content). Pinning the merge base catches the case that matters — the PR's base
# being REPOINTED (`gh pr edit --base`), which moves the merge base and changes
# what would merge while the head sha stays the same — and is stable otherwise.
# extensions/review-enforcer re-derives it and refuses with `base_advanced` on a
# mismatch, or `base_unverifiable` when it cannot be read. Empty for
# clean/clean-micro: their record shape is unchanged (the same base-blindness
# there is pre-existing, filed as agent-infra #1362).
MB_FIELD=""
if [ "$VERDICT" = "clean-low" ] && [ -n "${MB:-}" ]; then
  MB_FIELD="\"merge_base_sha\":\"$MB\","
fi
# #2982: the reviewed diff, bound into the record. Empty when unavailable, so a
# network failure cannot become a pass. Composed as its OWN field rather than a
# second printf branch, so it COMPOSES with MB_FIELD (#1348) rather than
# competing with it — a record may legitimately carry both.
DIFF_FIELD=""
if [ -n "${DIFF_HASH:-}" ]; then
  DIFF_FIELD="\"diff_sha256\":\"$DIFF_HASH\","
fi
# tortoise#7391 — MINT PROVENANCE, and the end of the carry overwriting the mint time.
# A carried record used to be byte-identical in shape to a freshly-minted one
# and showed the CARRY (≈ merge) time in reviewed_at, so the time the review
# actually happened was unrecoverable after the fact — the record this issue's
# live instance rests on reads reviewed_at 03:35:39Z while its reviews are from
# the previous day. `mint` makes the two distinguishable; `carried_from` and
# `carried_at` say what was carried and when; reviewed_at is restored to the
# ORIGINAL mint time recovered from the record this carry supersedes.
MINT_FIELDS="\"mint\":\"fresh\","
if [ -n "$CARRY_ARM" ]; then
  MINT_FIELDS="\"mint\":\"carried\",\"carried_from\":\"$ORIG_SHA\",\"carried_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\","
fi
EVIDENCE_FIELD=""
if [ -n "$EVIDENCE_VERIFIED" ]; then
  EVIDENCE_FIELD="\"evidence\":\"$EVIDENCE_VERIFIED\","
fi
REVIEWED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -n "$CARRY_ARM" ]; then
  # $FILE is read BEFORE the mv below, so it still holds the record this carry
  # supersedes; that record names the head the verdict was minted at, so its
  # reviewed_at IS the mint time.
  PRIOR_HEAD=""; PRIOR_AT=""
  if [ -f "$FILE" ]; then
    PRIOR_HEAD="$(sed -n 's/.*"head_sha":"\([^"]*\)".*/\1/p' "$FILE" | command head -1)"
    PRIOR_AT="$(sed -n 's/.*"reviewed_at":"\([^"]*\)".*/\1/p' "$FILE" | command head -1)"
  fi
  if [ -n "$PRIOR_AT" ] && [ "$PRIOR_HEAD" = "$ORIG_SHA" ]; then
    REVIEWED_AT="$PRIOR_AT"
    echo "tortoise#7391 carry provenance: reviewed_at preserved as the original mint time $PRIOR_AT (mint=carried, carried_from=${ORIG_SHA:0:12}…)" >&2
  else
    echo "⚠️ tortoise#7391: CARRIED record for ${REPO:-<no-repo>}#$PR and the ORIGINAL mint time is not recoverable (no record on disk names ${ORIG_SHA:0:12}… with a reviewed_at) — reviewed_at is the CARRY time, not the mint time; \`mint\`/\`carried_at\` say so." >&2
  fi
fi
if [ -n "$REPO" ]; then
  printf '{"pr":%d,"head_sha":"%s",%s%s%s%s"verdict":"%s","repo":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$SHA" "$MB_FIELD" "$DIFF_FIELD" "$MINT_FIELDS" "$EVIDENCE_FIELD" "$VERDICT" "$REPO" "$REVIEWED_AT" > "$TMP"
else
  printf '{"pr":%d,"head_sha":"%s",%s%s%s%s"verdict":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$SHA" "$MB_FIELD" "$DIFF_FIELD" "$MINT_FIELDS" "$EVIDENCE_FIELD" "$VERDICT" "$REVIEWED_AT" > "$TMP"
fi
mv "$TMP" "$FILE"
# Migration (#426): a legacy <pr>.json that belongs to THIS repo is
# superseded by the qualified file — remove it so stale number-keyed copies
# can't collide later. Discriminate "no repo field at all" from "unparseable":
# only a legacy record whose embedded repo EXACTLY equals $REPO is deleted;
# anything else (foreign repo, formatted JSON we can't parse, no field) is
# LEFT ALONE — never delete a file that might be another repo's data.
if [ -n "$LEGACY" ] && [ -f "$LEGACY" ]; then
  LEGACY_REPO="$(sed -n 's/.*"repo":"\([^"]*\)".*/\1/p' "$LEGACY" | command head -1)"
  if [ -n "$LEGACY_REPO" ] && [ "$LEGACY_REPO" = "$REPO" ]; then
    rm -f "$LEGACY"
  fi
fi

# ── Auto-post review evidence into the PR body (#163 follow-up) ──────────
# The pipeline compliance check (c) looks for review markers in the PR
# body/commits. Real reviews were lagging the gate because nothing posted
# the evidence (PR #163 merged RED for exactly this). Append a marker line
# here, at record time. Idempotent; best-effort — NEVER fails the record.
if command -v gh >/dev/null 2>&1 && [ -n "$REPO" ]; then
  # Sign the marker (HMAC-SHA256 over the marker text, AI_REVIEW_GATE_KEY) so
  # the GitHub ai-review-gate required check cannot be satisfied by editing
  # the PR body (#2055). GATE_KEY is resolved once, ABOVE the stale-sha guard,
  # because the carry-forward arm must verify a prior marker's HMAC there.
  # Missing key → warn loudly and post UNSIGNED (the gate will fail closed).
  # The record is written from these same args, so record and marker are
  # consistent by construction (head_sha == $SHA, verdict == $VERDICT).
  # The marker text is a SEPARATE contract from the record filename: the
  # external ai-review-gate required check regex-matches
  #   ^review recorded: reviews/<PR>.json verdict=… @ <sha> (<owner/repo>) sig=…
  # (tortoise .github/workflows/ai-review-gate.yml), so the marker KEEPS the
  # legacy-style reviews/<PR>.json reference even though the record file is
  # now repo-qualified (#426). Never rename it to match the file.
  # #2982: bind the reviewed DIFF into the signed text when available. The gate
  # accepts a marker whose @ sha is stale iff its diff= equals the PR's live
  # diff hash, so a merge-only branch update no longer invalidates a correct
  # verdict. Absent → legacy sha-only shape (gate's sha-match path governs).
  if [ -n "${DIFF_HASH:-}" ]; then
    MARKER="review recorded: reviews/${PR}.json verdict=${VERDICT} @ ${SHA} diff=${DIFF_HASH} (${REPO})"
  else
    MARKER="review recorded: reviews/${PR}.json verdict=${VERDICT} @ ${SHA} (${REPO})"
  fi
  if [ -n "$GATE_KEY" ]; then
    SIG="$(printf '%s' "$MARKER" | command openssl dgst -sha256 -hmac "$GATE_KEY" 2>/dev/null | awk '{print $NF}' || true)"
    if [ -n "$SIG" ]; then
      MARKER="${MARKER} sig=${SIG}"
    else
      echo "⚠️ could not compute marker signature (openssl?) — posting unsigned marker; ai-review-gate will fail" >&2
    fi
  else
    echo "⚠️ AI_REVIEW_GATE_KEY not configured (env or ~/.pi/agent/.ai-review-gate-key) — posting unsigned marker; ai-review-gate required check will fail. Configure the key to match the repo secret." >&2
  fi
  # Read the PR body — distinguish a genuinely EMPTY body (post marker-only)
  # from a GET FAILURE (skip the post loudly — never clobber the description).
  if BODY="$(command gh api "repos/$REPO/pulls/$PR" --jq .body 2>/dev/null)"; then
    [ "$BODY" = "null" ] && BODY=""
  else
    echo "⚠️ record-review: could not read PR body (transient API failure?) — evidence post skipped; record still saved. Re-run record-review.sh to retry the post." >&2
    exit 0
  fi
  # Idempotent append — post even when the body is EMPTY (an empty body must
  # not silently skip the evidence post; the gate would fail with no trace).
  MISSING=""
  if ! grep -qF "$MARKER" <<<"$BODY"; then
    MISSING="$MARKER"
  fi
  if [ -n "$MISSING" ]; then
    if [ -n "$BODY" ]; then
      NEWBODY="${BODY}

${MISSING}"
    else
      NEWBODY="$MISSING"
    fi
    jq -n --arg body "$NEWBODY" '{body: $body}' 2>/dev/null \
      | command gh api -X PATCH "repos/$REPO/pulls/$PR" --input - >/dev/null 2>&1 \
      && echo "review evidence posted to $REPO#$PR body" \
      || echo "note: could not post review evidence to PR body (record still saved)" >&2
  fi
else
  echo "⚠️ record-review: evidence post skipped (gh CLI missing or REPO undetectable) — the record is saved, but the ai-review-gate required check will fail until evidence is posted manually." >&2
fi
fi # /main guard (#513)
