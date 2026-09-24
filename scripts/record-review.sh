#!/usr/bin/env bash
# record-review.sh <pr> <head_sha> [verdict] [repo]
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
    repo="$(printf '%s' "$m" | tr 'A-Z' 'a-z' | grep -oE 'https://github.com/[^/[:space:],;)]+/[^/[:space:],;)]+/issues/[0-9]+' | sed -E 's#https://github.com/([^/]+/[^/]+)/issues/[0-9]+.*#\1#' | head -1 || true)"
    num="$(printf '%s' "$m" | grep -oE '/issues/[0-9]+$' | grep -oE '[0-9]+' | head -1 || true)"
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
#   * check-pipeline-compliance.sh::pr_is_artifact_only (:709) is check (a)'s
#     closure fallback: it admits ANY file under docs/ (so `docs/evil.sh` would
#     be an "artifact"), skills/**/*.md (agent-executable instructions) and
#     .github/CODEOWNERS (review routing — enforcement input).
#   * extensions/verification-gate::isShapeExemptFile (:759) is a LOCAL
#     pre-flight skip; it admits .md/.css/.html ANYWHERE, including build
#     inputs such as templates/AGENTS.base.md.
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
POSITIONAL=()
_argv=("$@")
_i=0
while [ "$_i" -lt "${#_argv[@]}" ]; do
  _arg="${_argv[$_i]}"
  case "$_arg" in
    --force-stale) FORCE_STALE=1 ;;
    --second-model|--second-model-independent)
      echo "record-review.sh: '$_arg' was removed with the second-model subsystem (#980/#979) — this repo is single-model; refusing to record. Drop it from the invocation." >&2
      exit 2 ;;
    -*) echo "record-review.sh: unknown option '$_arg' — the second-model gate was removed (#980/#979). usage: record-review.sh <pr> <head_sha> [verdict] [repo] [--force-stale]" >&2
        exit 2 ;;
    *) POSITIONAL+=("$_arg") ;;
  esac
  _i=$((_i + 1))
done
if [ "${#POSITIONAL[@]}" -gt 4 ]; then
  echo "record-review.sh: too many arguments (${#POSITIONAL[@]}) — usage: record-review.sh <pr> <head_sha> [verdict] [repo] [--force-stale]" >&2
  exit 2
fi
if [ "${#POSITIONAL[@]}" -gt 0 ]; then
  set -- "${POSITIONAL[@]}"
else
  set --
fi
PR="${1:?usage: record-review.sh <pr> <head_sha> [verdict] [repo] [--force-stale]}"
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
# Auto-detect repo (owner/name) when not passed explicitly. Detect BEFORE
# format-checking: an omitted repo is legal here (auto-detected), and when
# nothing is detectable the record proceeds repo-less for backward compat.
if [ -z "$REPO" ]; then
  REPO="${GH_REPO:-}"
fi
if [ -z "$REPO" ]; then
  REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
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
# Sets the globals DIFF_HASH (normalized) and LEGACY_DIFF_HASH (raw) from one
# diff fetch. It deliberately sets GLOBALS rather than printing: a `$(...)`
# capture would run the assignment in a subshell and lose LEGACY_DIFF_HASH.
diff_hash_for_pr() { # <pr>
  local pr="$1" tmp norm
  command -v gh >/dev/null 2>&1 || return 0
  command -v openssl >/dev/null 2>&1 || return 0
  tmp="$(mktemp 2>/dev/null)" || return 0
  norm="$(mktemp 2>/dev/null)" || { rm -f "$tmp"; return 0; }
  # shellcheck disable=SC2064
  trap "rm -f '$tmp' '$norm'" RETURN 2>/dev/null || true
  if gh api -H "Accept: application/vnd.github.v3.diff" \
       "repos/$REPO/pulls/$pr" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    LEGACY_DIFF_HASH="$(openssl dgst -sha256 < "$tmp" | awk '{print $NF}')"
    if command -v python3 >/dev/null 2>&1 && [ -f "$DIFF_NORMALIZER" ] \
       && python3 "$DIFF_NORMALIZER" < "$tmp" > "$norm" 2>/dev/null; then
      DIFF_HASH="$(openssl dgst -sha256 < "$norm" | awk '{print $NF}')"
    else
      # Fail OPEN to the pre-#1362 raw digest: the consumer still accepts it as
      # the legacy hash, so the marker stays verifiable — but a base-only update
      # will keep refusing carry-forward. Name that loudly rather than minting a
      # digest no consumer can verify.
      echo "⚠️ #1362: the diff normalizer is unavailable (need python3 + $DIFF_NORMALIZER) — hashing the RAW diff; a base-only update will keep refusing carry-forward until it is installed" >&2
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
    echo "⚠️ #2982: could not compute this PR's diff hash (gh/API/openssl unavailable?) — recording a legacy sha-only marker; it will NOT carry across a branch update" >&2
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

# #2982 — carry-forward arm: when the head has moved but the PR already carries
# signed evidence for EXACTLY this diff (a marker whose diff= equals the live
# diff hash), the head moved without the reviewed artifact changing (a
# merge-only update). Re-record against the CURRENT head with that diff hash,
# which is precisely what the gate needs — instead of refusing and deadlocking.
# When no such marker exists the diff is genuinely unreviewed → still refuse.
if [ -n "$REPO" ] && command -v gh >/dev/null 2>&1; then
  CURRENT_HEAD="$(gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null || true)"
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
      PRIOR_BODY="$(gh api "repos/$REPO/pulls/$PR" --jq .body 2>/dev/null || true)"
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
        PRIOR_EXPECT="$(printf '%s' "$PRIOR_TEXT" | openssl dgst -sha256 -hmac "$GATE_KEY" 2>/dev/null | awk '{print $NF}' || true)"
        if [ -n "$PRIOR_EXPECT" ] && [ "$PRIOR_SIG" = "$PRIOR_EXPECT" ]; then
          PRIOR_DIFF="$DIFF_HASH"
        else
          echo "⚠️ #784: found prior evidence in the PR body with the right shape but a BAD SIGNATURE — ignoring it (the PR body is not a trust boundary)" >&2
        fi
      fi
    fi
    if [ -n "$PRIOR_DIFF" ]; then
      echo "#2982 carry-forward: head moved ${SHA:0:12}… → ${CURRENT_HEAD:0:12}…, but the reviewed diff is unchanged (diff=${DIFF_HASH}) and already carries signed evidence — recording against the CURRENT head" >&2
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
    BODY="$(gh api "repos/$REPO/pulls/$PR" --jq .body 2>/dev/null || true)"
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
        echo "⚠️ clean-micro tier guard: no same-repo closing-issue ref found in the PR body of $REPO#$PR — tier attestation UNVERIFIED (record proceeds; body refs: $(printf '%s' "$BODY" | grep -oE '(fix(es|ed)?|close(s|d)?|resolve(s|d)?)[[:space:]]*[^[:space:],;)]*' | head -c 200 || true))" >&2
      else
        # Per-ref label fetch. A fetch failure marks THAT ref undeterminable —
        # never refuse on a failed fetch (mirrors the stale-sha fail-open).
        REFUSED=""
        MICRO_SEEN=""
        while IFS= read -r ref; do
          [ -z "$ref" ] && continue
          num="${ref##*#}"
          LABELS="$(gh api "repos/$REPO/issues/$num/labels" --jq '.[].name' 2>/dev/null || true)"
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
            OFFENDING_LABEL="$(printf '%s\n' "$LABELS" | grep -E '^complexity:' | head -1)"
            REFUSED=1
            echo "❌ clean-micro tier guard: $REPO#$PR closes $ref, whose complexity label is \"$OFFENDING_LABEL\" — clean-micro certifies the MICRO process only and is REFUSED for a non-micro linked issue." >&2
            echo "   → Run the code-review skill on the current head and record clean:" >&2
            echo "   →   record-review.sh $PR <head-sha> clean $REPO" >&2
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
  META="$(gh api "repos/$REPO/pulls/$PR" --jq '[(.head.sha), (.base.sha), ((.changed_files // 0) | tostring)] | @tsv' 2>/dev/null || true)"
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
  CMP="$(gh api "repos/$REPO/compare/$META_BASE...$SHA" --jq '.merge_base_commit.sha as $mb | "mb\t\($mb)", (.files[]? | [.status, .filename, (.previous_filename // "")] | @tsv)' 2>/dev/null || true)"
  MB="$(printf '%s\n' "$CMP" | head -1 | cut -f2)"
  RAW="$(printf '%s\n' "$CMP" | tail -n +2)"
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
    echo "   →   record-review.sh $PR $SHA clean $REPO" >&2
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
if [ -n "$REPO" ]; then
  printf '{"pr":%d,"head_sha":"%s",%s%s"verdict":"%s","repo":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$SHA" "$MB_FIELD" "$DIFF_FIELD" "$VERDICT" "$REPO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP"
else
  printf '{"pr":%d,"head_sha":"%s",%s%s"verdict":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$SHA" "$MB_FIELD" "$DIFF_FIELD" "$VERDICT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP"
fi
mv "$TMP" "$FILE"
# Migration (#426): a legacy <pr>.json that belongs to THIS repo is
# superseded by the qualified file — remove it so stale number-keyed copies
# can't collide later. Discriminate "no repo field at all" from "unparseable":
# only a legacy record whose embedded repo EXACTLY equals $REPO is deleted;
# anything else (foreign repo, formatted JSON we can't parse, no field) is
# LEFT ALONE — never delete a file that might be another repo's data.
if [ -n "$LEGACY" ] && [ -f "$LEGACY" ]; then
  LEGACY_REPO="$(sed -n 's/.*"repo":"\([^"]*\)".*/\1/p' "$LEGACY" | head -1)"
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
    SIG="$(printf '%s' "$MARKER" | openssl dgst -sha256 -hmac "$GATE_KEY" 2>/dev/null | awk '{print $NF}' || true)"
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
  if BODY="$(gh api "repos/$REPO/pulls/$PR" --jq .body 2>/dev/null)"; then
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
      | gh api -X PATCH "repos/$REPO/pulls/$PR" --input - >/dev/null 2>&1 \
      && echo "review evidence posted to $REPO#$PR body" \
      || echo "note: could not post review evidence to PR body (record still saved)" >&2
  fi
else
  echo "⚠️ record-review: evidence post skipped (gh CLI missing or REPO undetectable) — the record is saved, but the ai-review-gate required check will fail until evidence is posted manually." >&2
fi
fi # /main guard (#513)
