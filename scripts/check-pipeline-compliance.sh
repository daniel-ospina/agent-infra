#!/usr/bin/env bash
# check-pipeline-compliance.sh — deterministic (no-LLM) CI gate: verifies a PR
# followed the agent pipeline before merge.
#
# The gate checks process evidence, not code quality (that is the code-review
# skill's job; lint/typecheck/tests are separate CI). For a PR it checks, in
# order:
#
#   a. LINKED ISSUE      — PR body references an issue via a closing keyword
#                          (Fixes #N / Closes #N / Resolves #N, plus
#                          owner/repo#N or https://github.com/owner/repo/issues/N
#                          for cross-repo issues). For cross-repo refs the
#                          labels (tier) and scoping comments (checks b–e) are
#                          fetched from the issue's OWN repo, not the PR's.
#                          A PR whose diff is ENTIRELY under docs/ may
#                          instead use a NON-closing traceability keyword
#                          (Refs / Part of / Advances / Tracks / Relates to).
#                          Rationale: a planning-artifact PR implements no
#                          runtime work, so demanding a closing keyword would
#                          force a FALSE close of the linked issue — often an
#                          open parent whose children carry the work. The
#                          closing form always wins when both are present,
#                          and the fallback is unreachable for any PR that
#                          touches a non-docs file.
#   b. SCOPING COMMENT   — linked issue has a comment with the
#                          `<!-- issue-scoping:` marker (posted by the
#                          issue-scoping skill)
#   c. CODE-REVIEW EVID  — PR body OR any PR commit message references review
#                          dispatch (code-review | reviewer | [review] |
#                          VGATE | review recorded | review-enforcer)
#   d. PLAN DOC          — complexity:standard/complex issues need a plan doc:
#                          the PR adds/modifies a file under docs/plans/*.md,
#                          OR the scoping comment contains a `Wiring` section
#                          (wiring-check table, produced by writing-plans /
#                          issue-scoping)
#   e. TEST-COVERAGE EVID — PRs touching runtime code (extensions/**/*.ts
#                          excluding *.test.ts, plus extensions/**/*.js and
#                          bin/*.js) must show EITHER new/updated test files
#                          (*.test.ts / *.test.js, any path) in the diff OR
#                          test-run markers in PR body/commits (tests green,
#                          N passed, N/N ratio, VGATE PASS, test suite,
#                          pytest, npm test, vitest)
#   f. SECOND-MODEL GATE  — #716: when the diff touches the second-model
#                          guarded surface (the designation config, its guard
#                          script, the four second-model gate skills,
#                          AGENTS.md / the base template, docs/providers.md,
#                          record-review.sh, or this script) the PR body must
#                          carry `[SECOND-MODEL-GATE] model=<id>
#                          independent=<yes|NO|DEGRADED>`; `NO`/`DEGRADED` and a
#                          build-equivalent id FAIL. ONE bootstrap exemption:
#                          when the PR's BASE ref does not carry
#                          pi-bootstrap/pi-config/second-model.json, (f) is a
#                          loud WARN instead of a failure — keyed ONLY on the
#                          file's absence on base (never a branch name, PR
#                          number, or commit range), and never obtainable by a
#                          diff that touches the file.
#
# Tier exemptions (deterministic, from issue labels):
#   complexity:micro          → checks b–e skipped (a still required)
#   no complexity:standard/…  → check d skipped (b, c, e still required)
#   docs/skills/templates/config-only PR (no runtime code) → e skipped
#
# Every failure names the missing artifact AND the skill that produces it.
# ALL failures are printed (not just the first). Exit codes:
#   0 = compliant   1 = blocked   2 = usage/script error.
#
# Usage:
#   bash scripts/check-pipeline-compliance.sh <PR_NUMBER>
#   PR_NUMBER=123 bash scripts/check-pipeline-compliance.sh
#   GH_REPO=owner/repo PR_NUMBER=123 bash scripts/check-pipeline-compliance.sh
#
# Env:
#   GH_REPO                       owner/repo (default: auto-detect from git remote)
#   PR_NUMBER                     PR number (or positional arg)
#   PIPELINE_COMPLIANCE_SKIP      1 = emergency override: skip gate, loud warning
#   PIPELINE_COMPLIANCE_DRY_RUN   1 = print what WOULD be checked, no gh calls
#   PIPELINE_COMPLIANCE_FAIL_ALL  1 = with DRY_RUN: simulate failures to exercise
#                                 failure output paths offline (unit-testable)
#   PIPELINE_COMPLIANCE_SELF_TEST 1 = run parse_issue_ref self-test, no gh calls
set -euo pipefail

# ── Inputs ──────────────────────────────────────────────────────────────────
PR_NUMBER="${1:-${PR_NUMBER:-}}"
GH_REPO="${GH_REPO:-}"
DRY_RUN="${PIPELINE_COMPLIANCE_DRY_RUN:-0}"
FAIL_ALL="${PIPELINE_COMPLIANCE_FAIL_ALL:-0}"
# Authoritative PR file count (pulls .changed_files). Set by the live fetch;
# files_rows demands the validated DISTINCT-new-path count equal it, so a
# forged or truncated diff list cannot read as complete. Empty (or 0) = not
# enforced — offline simulations construct the list in-process.
FILES_EXPECTED=""
# The PR's current head sha (pulls .head.sha), used to bind the recorded
# [SECOND-MODEL-GATE] line to this PR's head (C3). Empty in dry-run/offline
# simulations that do not set PR_HEAD_SHA explicitly.
PR_HEAD_SHA="${PIPELINE_SM_HEAD_SHA:-}"

usage() {
  cat >&2 <<'EOF'
Usage:
  bash scripts/check-pipeline-compliance.sh <PR_NUMBER>
  PR_NUMBER=123 GH_REPO=owner/repo bash scripts/check-pipeline-compliance.sh

Env:
  GH_REPO                       owner/repo (default: auto-detect from git remote)
  PIPELINE_COMPLIANCE_SKIP=1    emergency override (loud warning)
  PIPELINE_COMPLIANCE_DRY_RUN=1 print what WOULD be checked (no gh calls)
  PIPELINE_COMPLIANCE_FAIL_ALL=1 with DRY_RUN: simulate all failures
  PIPELINE_COMPLIANCE_SELF_TEST=1 parser-only self-test (no gh calls)
EOF
}

# ── Emergency override ──────────────────────────────────────────────────────
if [[ "${PIPELINE_COMPLIANCE_SKIP:-0}" == "1" ]]; then
  echo "⚠️  ⚠️  PIPELINE_COMPLIANCE_SKIP=1 — PIPELINE COMPLIANCE GATE SKIPPED (emergency override)." >&2
  echo "    This PR can merge WITHOUT scoping/code-review/plan evidence." >&2
  echo "    Review why the override was needed and restore the gate." >&2
  exit 0
fi

# ── Guards ──────────────────────────────────────────────────────────────────
if [[ -z "$PR_NUMBER" && "${PIPELINE_COMPLIANCE_SELF_TEST:-0}" != "1" ]]; then
  echo "❌ No PR number given." >&2
  usage
  exit 2
fi
if [[ ! "$PR_NUMBER" =~ ^[0-9]+$ && "${PIPELINE_COMPLIANCE_SELF_TEST:-0}" != "1" ]]; then
  echo "❌ PR_NUMBER must be numeric, got: '$PR_NUMBER'." >&2
  exit 2
fi

# Auto-detect owner/repo from the git remote when GH_REPO is unset.
if [[ -z "$GH_REPO" ]]; then
  ROOT="$(cd "$(dirname "$0")/.." && pwd)"
  REMOTE="$(git -C "$ROOT" remote get-url origin 2>/dev/null || true)"
  case "$REMOTE" in
    *github.com:*/*.git) GH_REPO="${REMOTE#*github.com:}"; GH_REPO="${GH_REPO%.git}" ;;
    *github.com/*.git)   GH_REPO="${REMOTE#*github.com/}"; GH_REPO="${GH_REPO%.git}" ;;
    *github.com/*)       GH_REPO="${REMOTE#*github.com/}" ;;
  esac
fi
if [[ -z "$GH_REPO" ]]; then
  echo "❌ Could not determine GH_REPO. Set GH_REPO=owner/repo or run from a repo with a github.com origin." >&2
  exit 2
fi
if [[ ! "$GH_REPO" =~ ^[^/]+/[^/]+$ ]]; then
  echo "❌ GH_REPO must be owner/repo, got: '$GH_REPO'." >&2
  exit 2
fi

if [[ "$DRY_RUN" != "1" && "${PIPELINE_COMPLIANCE_SELF_TEST:-0}" != "1" ]]; then
  command -v gh >/dev/null 2>&1 || { echo "❌ gh CLI not found — install it (https://cli.github.com) or set PIPELINE_COMPLIANCE_DRY_RUN=1." >&2; exit 2; }
  command -v jq >/dev/null 2>&1 || { echo "❌ jq not found — install it or set PIPELINE_COMPLIANCE_DRY_RUN=1." >&2; exit 2; }
fi

# ── Helpers ─────────────────────────────────────────────────────────────────
FAILURES=0
pass() { printf '✅ [%s] %s\n' "$1" "$2"; }
fail() { printf '❌ [%s] %s\n' "$1" "$2"; FAILURES=$((FAILURES + 1)); }

# Closing-keyword pattern (check a's default) and the NON-closing
# traceability pattern (the docs-only fallback). \b anchors the TRACE keywords
# so a substring cannot masquerade as one ("prefs #42" must not read as
# "refs #42"). The CLOSING pattern deliberately keeps its historic UNANCHORED
# form: parse_issue_ref is kept byte-identical to
# record-review.sh::closing_issue_refs (a documented cross-script contract),
# and anchoring it here would silently change check (a) for EVERY PR. That
# unanchored behaviour is pinned by this script's own SELF_TEST, not by
# record-review.test.sh.
CLOSING_KW='(fix(es|ed)?|close(s|d)?|resolve(s|d)?)'
TRACE_KW='\b(ref(s|erences?)?|part[[:space:]]+of|advance(s|d)?|track(s|ed)?|relates?[[:space:]]+to)'

# parse_issue_ref <text> [<kw-pattern>] — print the first issue reference
# resolved by a closing keyword in <text>, as "owner/repo#N" ("" when none).
# The repo defaults to $GH_REPO for a bare "#N". Accepted forms, in priority order:
#   a. full URL  https://github.com/<owner>/<repo>/issues/<n>
#                (must NOT match .../pull/<n>)
#   b. owner/repo#<n>
#   c. bare #<n> → repo = $GH_REPO
# Each form greps the closing keyword directly followed by the reference (so
# e.g. "resolves SLACK_APPROVAL_FILE" is not mistaken for an issue ref).
parse_issue_ref() {
  local text="$1" kwpat="${2:-$CLOSING_KW}" m repo num kw
  kw="$kwpat"
  # a. full URL — /issues/<n> explicitly, never /pull/<n>.
  m="$(printf '%s\n' "$text" | grep -ioE "${kw}[[:space:]]*https://github.com/[^/[:space:],;)]+/[^/[:space:],;)]+/issues/[0-9]+" | head -1 || true)"
  if [[ -n "$m" ]]; then
    repo="$(printf '%s' "$m" | tr 'A-Z' 'a-z' | grep -oE 'https://github.com/[^/[:space:],;)]+/[^/[:space:],;)]+/issues/[0-9]+' | sed -E 's#https://github.com/([^/]+/[^/]+)/issues/[0-9]+.*#\1#' | head -1 || true)"
    num="$(printf '%s' "$m" | grep -oE '/issues/[0-9]+$' | grep -oE '[0-9]+' | head -1 || true)"
    if [[ -n "$repo" && -n "$num" ]]; then printf '%s#%s' "$repo" "$num"; return; fi
  fi
  # b. owner/repo#<n>
  m="$(printf '%s\n' "$text" | grep -ioE "${kw}[[:space:]]*[^/[:space:],;)]+/[^/[:space:],;)]+#[0-9]+" | head -1 || true)"
  if [[ -n "$m" ]]; then
    repo="$(printf '%s' "$m" | grep -oE '[^/[:space:],;)]+/[^/[:space:],;)]+#[0-9]+$' | cut -d'#' -f1 || true)"
    num="$(printf '%s' "$m" | grep -oE '#[0-9]+$' | tr -d '#' || true)"
    if [[ -n "$repo" && -n "$num" ]]; then printf '%s#%s' "$repo" "$num"; return; fi
  fi
  # c. bare #<n> → repo = $GH_REPO
  m="$(printf '%s\n' "$text" | grep -ioE "${kw}[[:space:]]*#[0-9]+" | head -1 || true)"
  if [[ -n "$m" ]]; then
    num="$(printf '%s' "$m" | grep -oE '#[0-9]+$' | tr -d '#' || true)"
    if [[ -n "$num" ]]; then printf '%s#%s' "$GH_REPO" "$num"; fi
  fi
}

# parse_trace_ref <text> — like parse_issue_ref, but matching the NON-closing
# traceability keywords (Refs / Part of / Advances / Tracks / Relates to).
# Never call this unconditionally: a non-closing reference asserts "this PR
# advances #N", not "this PR completes #N", so it satisfies check (a) only
# for a docs-only PR — see resolve_issue_ref.
parse_trace_ref() { parse_issue_ref "$1" "$TRACE_KW"; }

# files_rows <files> — validate the UNTRUSTED diff list from pulls/files and
# print its well-formed rows. Returns 1 without output if ANY row is
# malformed, because a single bad row makes the whole list untrustworthy.
#
# Every consumer of the file list MUST go through this (or pr_is_docs_only,
# which wraps it). Parsing the raw rows independently is a fail-open: git
# allows newlines and tabs inside a path, and GH reports filenames raw, so one
# real file can be framed as several well-formed-looking rows. A row forged
# that way could add a `docs/plans/*.md` path (satisfying check d) or a
# `*.test.ts` path (satisfying check e) without such a file existing.
#
# Row-by-row validation alone cannot catch a forgery whose injected material
# happens to be well formed, so when $FILES_EXPECTED holds a positive integer
# the DISTINCT new-path count must EQUAL it (the PR's authoritative
# .changed_files). Equality of distinct paths is what makes the list complete.
#
# Compare DISTINCT paths, not rows: `.changed_files` counts distinct paths but
# `pulls/files` returns one entry per diff entry, so a delete+add on one path
# (e.g. a symlink converted to a regular file) is two rows for one path.
# Comparing rows would falsely block such a PR — this repo has produced them.
files_rows() {
  local rows out count
  rows="$(printf '%s\n' "$1" | sed -e '/^$/d')"
  [[ -n "$rows" ]] || return 1
  out="$(printf '%s\n' "$rows" | LC_ALL=C awk -F '\t' '
    {
      if (NF != 3) { bad = 1; next }
      if ($2 == "") { bad = 1; next }
      s = $1
      # The GitHub diff-entry status enum. `unchanged` is documented and must
      # be accepted, or a legitimate docs-only PR is wrongly BLOCKED.
      if (s != "added" && s != "modified" && s != "removed" && s != "renamed" && s != "changed" && s != "copied" && s != "unchanged") { bad = 1; next }
      # A rename must carry its old path; without it we cannot judge both ends.
      if (s == "renamed" && $3 == "") { bad = 1; next }
      print $1 "\t" $2 "\t" $3
    }
    END { if (bad) exit 1 }
  ')" || return 1
  [[ -n "$out" ]] || return 1
  if [[ "${FILES_EXPECTED:-}" =~ ^[1-9][0-9]*$ ]]; then
    count="$(printf '%s\n' "$out" | LC_ALL=C awk -F '\t' '{ print $2 }' | LC_ALL=C sort -u | wc -l | tr -d ' ')"
    [[ "$count" == "$FILES_EXPECTED" ]] || return 1
  fi
  printf '%s\n' "$out"
}

# pr_is_docs_only <files> — true when the PR's diff lies ENTIRELY under docs/.
# `files` is the "<status><TAB><filename><TAB><old>" list from the pulls/files
# fetch. Fails CLOSED on anything it cannot prove, because this predicate is
# what unlocks check (a)'s non-closing keyword — a false `true` would let a
# code PR dodge closure. Four ways to be untrustworthy, all → NOT docs-only:
#   1. Empty/unreadable list (a broken fetch must never weaken closure).
#   2. Any row the shared validator rejects — malformed framing or an empty
#      filename. Git allows newlines and tabs INSIDE a path, and GH reports
#      filenames raw, so such a name splits one real file into several
#      well-formed-looking rows. An empty filename is likewise rejected — it
#      would otherwise vanish when command substitution strips the trailing
#      newline (order-dependent fail-open).
#   3. Any row whose OLD path ($3) is present but not under docs/ — checked for
#      EVERY status, not just `renamed`. A rename MOVES content out of the old
#      path, and a copy introduces that content at a second path; either way
#      the old path is part of the same diff, so both ends must be docs-only.
#      This must be status-independent because split-row framing can relocate
#      a non-docs old path onto a row whose status is not `renamed`.
#   4. At or above GitHub's documented 3000-entry cap for this endpoint the
#      response may be TRUNCATED. files_rows enforces DISTINCT-new-path
#      equality with the PR's authoritative .changed_files, and this predicate
#      additionally caps the distinct-path count at 3000, so a short
#      (truncated or forged) list never reads as docs-only.
pr_is_docs_only() {
  local rows count paths
  rows="$(files_rows "$1")" || return 1
  [[ -n "$rows" ]] || return 1
  # The 3000-entry cap counts DISTINCT paths, matching the files_rows guard and
  # the unit GitHub caps at. Counting ROWS would wrongly deny the traceability
  # fallback to a complete list of >=3000 diff entries with fewer distinct
  # paths (a delete+add pair is two rows for one path).
  count="$(printf '%s\n' "$rows" | LC_ALL=C awk -F '\t' '{ print $2 }' | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  [[ "$count" -lt 3000 ]] || return 1
  # Both ends of every row must be under docs/ (the new path always, the old
  # path whenever present).
  paths="$(printf '%s\n' "$rows" | LC_ALL=C awk -F '\t' '{ print $2; if ($3 != "") print $3 }')"
  [[ -n "$paths" ]] || return 1
  ! printf '%s\n' "$paths" | grep -qvE '^docs/'
}

# resolve_issue_ref <pr-body> <files> — check (a)'s resolution, shared with
# the live issue lookup so checks b–e always run against the SAME issue the
# gate reported in (a). The closing keyword wins outright; the docs-only
# traceability fallback is consulted only when no closing reference exists.
resolve_issue_ref() {
  local ref
  ref="$(parse_issue_ref "$1")"
  if [[ -z "$ref" ]] && pr_is_docs_only "$2"; then
    ref="$(parse_trace_ref "$1")"
  fi
  printf '%s' "$ref"
}

# fetch_json <api-path> <jq-expr> [paginate] [repo] — GET repos/$REPO/<path>
# via gh, print jq-filtered result to stdout. Pass "1" for list endpoints to
# page through all results (comments/commits/files/labels). Pass an explicit
# repo (owner/repo) to fetch from a repo other than $GH_REPO — used for
# cross-repo issue references, where labels/comments live on the issue's repo.
# In dry-run mode logs the call and prints nothing (simulates empty data).
fetch_json() {
  local path="$1" expr="$2" paginate="${3:-}" repo="${4:-$GH_REPO}"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "[dry-run] fetch: gh api repos/$repo/$path --jq '$expr'" >&2
    return 0
  fi
  local out rc
  if [[ "$paginate" == "1" ]]; then
    out="$(gh api "repos/$repo/$path" --paginate --jq "$expr" 2>&1)" || {
      rc=$?
      echo "❌ [fetch] gh api failed for repos/$repo/$path (exit $rc): $out" >&2
      echo "   Check GH_REPO, PR_NUMBER, and gh auth." >&2
      exit 2
    }
  else
    out="$(gh api "repos/$repo/$path" --jq "$expr" 2>&1)" || {
      rc=$?
      echo "❌ [fetch] gh api failed for repos/$repo/$path (exit $rc): $out" >&2
      echo "   Check GH_REPO, PR_NUMBER, and gh auth." >&2
      exit 2
    }
  fi
  printf '%s' "$out"
}

# ── Core checks ─────────────────────────────────────────────────────────────
# Runs against globals (set by the caller): PR_BODY, LABELS, SCOPING_COMMENT,
# COMMIT_MSGS, FILES. Prints pass/fail per check; returns failure count.
# ── #716 second-model gate (check f) helpers ────────────────────────────────
# The guarded surface includes the two workflows that RUN the guard (ci.yml
# runs the shipped-config check + the advisory probe + the fixture suite;
# ci-main.yml re-runs the shipped check + suite post-merge) and the suite
# itself: deleting or weakening any of them removes all verification with no
# gate line required (G11).
GUARDED_SURFACE_RE='^(pi-bootstrap/pi-config/second-model\.json|pi-bootstrap/pi-config/models\.json|pi-bootstrap/setup\.sh|scripts/check-second-model\.sh|scripts/record-review\.sh|scripts/check-pipeline-compliance\.sh|sync\.sh|\.husky/pre-commit|\.github/workflows/(pipeline-compliance|ci|ci-main)\.yml|tests/second-model/.*|AGENTS\.md|templates/AGENTS\.base\.md|docs/providers\.md|skills/(code-review|issue-scoping|plan-review|subagent-driven-development)/SKILL\.md)$'

SM_GUARD="$(cd "$(dirname "$0")/.." && pwd)/scripts/check-second-model.sh"
# Offline seam (tests): pin the guard's authority so check (f) never reads an
# ambient $HOME config. Unset in production → the guard's own default.
sm_equiv() {
  if [[ -n "${PIPELINE_SECOND_MODEL_LIVE_DIR:-}" ]]; then
    bash "$SM_GUARD" --equivalence "$1" --live-dir "$PIPELINE_SECOND_MODEL_LIVE_DIR"
  else
    bash "$SM_GUARD" --equivalence "$1"
  fi
}

# second_model_base_state — print "present", "absent" or "unresolvable" for
# pi-bootstrap/pi-config/second-model.json on the PR's BASE ref. The bootstrap
# exemption is a NARROW one-time carve-out keyed ONLY on the file's POSITIVE
# absence on base:
#   * never keyed on a branch name, PR number, or commit range;
#   * never obtainable by a diff that touches the file (the file's content on
#     base is what is read, and the base is the PR's base ref, not HEAD);
#   * once the file exists on base, enforcement is unconditional.
# C1: an UNRESOLVABLE base returns "unresolvable" — check (f) FAILS on it,
# because a base we cannot read cannot prove the file was ever absent. Only a
# base that POSITIVELY resolves to a commit lacking the file earns the WARN.
# GITHUB_BASE_SHA (set by CI from the PR's base) must resolve when set: if it
# does not, the workflow's base-fetch step is gone, and falling back to
# origin/main would silently disable the only merge-blocking second-model
# check. Local runs with no GITHUB_BASE_SHA fall back to the ref chain.
second_model_base_state() {
  # Test/simulation seam (offline, no git): ABSENT | PRESENT | UNRESOLVABLE,
  # or a literal file path (exists → present, missing → absent).
  if [ -n "${PIPELINE_SECOND_MODEL_BASE_FILE:-}" ]; then
    case "$PIPELINE_SECOND_MODEL_BASE_FILE" in
      ABSENT) printf 'absent'; return 0 ;;
      PRESENT) printf 'present'; return 0 ;;
      UNRESOLVABLE|UNRESOLVED) printf 'unresolvable'; return 0 ;;
    esac
    if [ -f "$PIPELINE_SECOND_MODEL_BASE_FILE" ]; then printf 'present'; else printf 'absent'; fi
    return 0
  fi
  local root ref
  root="$(cd "$(dirname "$0")/.." && pwd)"
  # G3: `<sha>^{commit}`, NOT a bare `<sha>`. `git rev-parse --verify --quiet
  # <40-hex>` returns 0 for a syntactically valid sha whose OBJECT IS ABSENT
  # (the existence guard was vacuous), after which `git show` failed and the
  # function reported "absent" — check (f) then took the bootstrap WARN
  # forever. `^{commit}` requires a real commit object (same for a raw-sha
  # PIPELINE_BASE_REF and for the HEAD^ fallback).
  if [ -n "${GITHUB_BASE_SHA:-}" ]; then
    if ! git -C "$root" rev-parse --verify --quiet "${GITHUB_BASE_SHA}^{commit}" >/dev/null 2>&1; then
      printf 'unresolvable'; return 0
    fi
    if git -C "$root" show "${GITHUB_BASE_SHA}:pi-bootstrap/pi-config/second-model.json" >/dev/null 2>&1; then
      printf 'present'; return 0
    fi
    printf 'absent'; return 0
  fi
  for ref in "origin/${GITHUB_BASE_REF:-}" "${GITHUB_BASE_REF:-}" \
             "${PIPELINE_BASE_REF:-}" "origin/main" "HEAD^"; do
    [ -n "$ref" ] || continue
    case "$ref" in origin/) continue ;; esac
    if git -C "$root" rev-parse --verify --quiet "${ref}^{commit}" >/dev/null 2>&1; then
      if git -C "$root" show "${ref}:pi-bootstrap/pi-config/second-model.json" >/dev/null 2>&1; then
        printf 'present'; return 0
      fi
      printf 'absent'; return 0
    fi
    # H3: a SHA-shaped ref that does not resolve is UNRESOLVABLE, never
    # "absent". The old loop `continue`d past it, so an absent-but-well-formed
    # `PIPELINE_BASE_REF` fell through to a resolving fallback and reported
    # "absent" → the bootstrap WARN → check (f) silently disabled. Named refs
    # (origin/main, HEAD^) still continue — they are best-effort fallbacks.
    if [[ "$ref" =~ ^[0-9a-f]{40}$ ]]; then
      printf 'unresolvable'; return 0
    fi
  done
  printf 'unresolvable'; return 0
}

run_checks() {
  local issue_ref="" issue_ref_kind="" issue_number="" issue_repo="" issue_display="" plan_file="" wiring_found="no"
  local sm_surface="" sm_line="" sm_line_raw="" sm_model="" sm_indep="" sm_sha="" sm_model_lc="" sm_base_state="" sm_rc=0
  local sm_malformed="" sm_pairs="" sm_m="" sm_i="" sm_m_lc="" sm_reserved="" sm_nonid="" sm_badindep="" sm_distinct="" sm_ndistinct=""
  local is_micro=false is_stdcomplex=false
  local tier="unspecified"
  local files_plain="" files_ends="" runtime_file="" test_evidence="" files_valid="" files_ok="false"

  # Plain filenames (status stripped) from the files fetch — shared by the
  # plan-doc (d) and test-coverage (e) checks. Derived from the VALIDATED row
  # set (files_rows), never from the raw rows: a filename containing a newline
  # can forge an extra well-formed row, and trusting it here would let a PR
  # invent a `docs/plans/*.md` path (check d) or a `*.test.ts` path (check e).
  #
  # files_ok records whether the list validated. Check (d) already fails
  # closed on an empty files_plain, but check (e) must NOT read an empty list
  # as "no runtime code" — it explicitly fails when files_ok is false.
  if files_valid="$(files_rows "$FILES" 2>/dev/null)"; then
    files_ok="true"
    files_plain="$(printf '%s\n' "$files_valid" | LC_ALL=C awk -F '\t' '{ print $2 }')"
    # Both ends of every row — the NEW path always, and the previous path
    # whenever present. Check (f) matches the guarded surface against BOTH
    # (C2): a content-identical rename moves a guarded file to a new name, and
    # matching only the new path would let the gate vanish.
    files_ends="$(printf '%s\n' "$files_valid" | LC_ALL=C awk -F '\t' '{ print $2; if ($3 != "") print $3 }')"
  fi

  echo "=== Pipeline Compliance Gate ==="
  echo "PR:   $GH_REPO#$PR_NUMBER"
  echo ""

  # a. LINKED ISSUE — closing keyword in the PR body; "owner/repo#N" (repo =
  # $GH_REPO for a bare "#N"). resolve_issue_ref is the SINGLE resolution
  # point, shared with the live issue lookup below, so check (a)'s verdict and
  # the issue that b–e actually run against can never drift apart.
  #
  # Docs-only PRs may fall back to a non-closing traceability keyword — a
  # planning-artifact PR closes no runtime work, so requiring a closing
  # keyword would force a FALSE close of the linked issue. The closing form
  # always wins when both are present, and the fallback is unreachable for
  # any PR that touches a non-docs file (pr_is_docs_only).
  issue_ref="$(resolve_issue_ref "$PR_BODY" "$FILES")"
  issue_ref_kind="closing"
  if [[ -n "$issue_ref" && -z "$(parse_issue_ref "$PR_BODY")" ]]; then
    issue_ref_kind="traceability"
  fi
  issue_number="${issue_ref##*#}"
  issue_repo="${issue_ref%#*}"
  issue_display="#$issue_number"
  if [[ -n "$issue_ref" && -n "$issue_repo" && "$issue_repo" != "$GH_REPO" ]]; then
    issue_display="$issue_repo#$issue_number"
  fi
  if [[ -n "$issue_ref" ]]; then
    if [[ "$issue_ref_kind" == "closing" ]]; then
      pass a "linked issue $issue_display (closing keyword in PR body)"
    else
      pass a "linked issue $issue_display (traceability keyword in PR body — docs-only PR, closure not implied)"
    fi
  else
    fail a "no linked issue — PR body must reference the issue with a closing keyword (\"Fixes #N\" / \"Closes #N\" / \"Resolves #N\", or owner/repo#N / full issue URL for cross-repo); a PR whose diff is ENTIRELY under docs/ may instead use \"Refs #N\" / \"Part of #N\" / \"Advances #N\" / \"Tracks #N\" / \"Relates to #N\"."
    echo "      Missing: issue reference in PR body."
    echo "      Invoke:  issue-scoping — run it, then reference the issue when opening the PR."
    echo ""
    echo "ℹ️  Checks b–e skipped: no linked issue to check against."
    echo ""
    return "$FAILURES"
  fi

  # Tier from issue labels.
  if printf '%s\n' "$LABELS" | grep -qx 'complexity:micro'; then is_micro=true; tier="micro"; fi
  if printf '%s\n' "$LABELS" | grep -qE '^complexity:(standard|complex)$'; then is_stdcomplex=true; tier="standard/complex"; fi
  echo "Tier: $tier (issue $issue_display)"
  echo ""

  # b. SCOPING COMMENT — `<!-- issue-scoping:` marker on the issue.
  if [[ "$is_micro" == "true" ]]; then
    echo "ℹ️  [b–e] Skipped: issue $issue_display is complexity:micro (micro-tier exemption)."
    echo ""
  else
    if printf '%s' "$SCOPING_COMMENT" | grep -q '<!-- issue-scoping:'; then
      pass b "scoping comment present on issue $issue_display (<!-- issue-scoping: marker)"
    else
      fail b "no scoping comment on issue $issue_display — a comment with the marker \"<!-- issue-scoping:\" is required."
      echo "      Missing: scoping comment on the linked issue."
      echo "      Invoke:  issue-scoping — it posts the scoping comment to the issue."
    fi

    # c. CODE-REVIEW EVIDENCE — PR body or any PR commit message.
    EVID_TEXT="$(printf '%s\n%s\n' "$PR_BODY" "$COMMIT_MSGS")"
    if printf '%s' "$EVID_TEXT" | grep -qiE 'code-review|reviewer|\[review\]|VGATE|review[[:space:]]+recorded|review-enforcer'; then
      # #513 verdict-tier binding (Approach B): clean-micro certifies the
      # MICRO process only (record-review.sh verifies the linked issue's
      # complexity:micro label at mint; micro skips checks b–e, so reaching
      # this branch means the issue is NOT micro). A non-micro PR whose
      # body/commits claim verdict=clean-micro is a false certification —
      # the record-review.sh marker carries the verdict verbatim. Remediation
      # includes the stale-marker removal step: record-review.sh APPENDS
      # markers and never removes them, so re-recording clean leaves the old
      # clean-micro line behind and this binding keeps firing.
      # Precision (#513 self-review catch): the binding must match the
      # record-review.sh MARKER shape (verdict=… @ <40-hex sha>) — never bare
      # prose mentioning the marker text (this PR's own description tripped
      # the bare-substring grep on the first pipeline-compliance run).
      if printf '%s' "$EVID_TEXT" | grep -qE 'verdict=clean-micro @ [0-9a-f]{40}'; then
        fail c "clean-micro verdict marker on a NON-micro linked issue (tier $tier) — clean-micro certifies the micro process only; run the code-review skill on the current head, re-record clean (record-review.sh <PR> <head-sha> clean <repo>), and remove the stale \"verdict=clean-micro\" marker line from the PR body."
      else
        pass c "code-review evidence in PR body/commits (review dispatch marker)"
      fi
    else
      fail c "no code-review evidence — PR body or a commit message must reference review dispatch."
      echo "      Accepts: code-review | reviewer | [review] | VGATE | review recorded | review-enforcer."
      echo "      Missing: review dispatch record in PR body or commits."
      echo "      Invoke:  code-review — it records review evidence (commit message / PR body)."
    fi

    # d. PLAN DOC — standard/complex only.
    if [[ "$is_stdcomplex" == "true" ]]; then
      plan_file="$(printf '%s\n' "$files_plain" | grep -E '^docs/plans/.*\.md$' | head -1 || true)"
      if printf '%s' "$SCOPING_COMMENT" | grep -qi 'wiring'; then wiring_found="yes"; fi
      # The Wiring alternative is file-independent, so it must be evaluated
      # BEFORE the files_ok guard: otherwise an unvalidatable list would
      # report check (d) as a plan-doc failure even when a Wiring section
      # satisfies it, asserting unprovability that is not true and breaking
      # (d)'s documented OR. The guard only names the real cause when NO plan
      # evidence is provable at all.
      if [[ -n "$plan_file" ]]; then
        pass d "plan doc in PR ($plan_file)"
      elif [[ "$wiring_found" == "yes" ]]; then
        pass d "plan evidence: Wiring section (wiring-check table) in scoping comment"
      elif [[ "$files_ok" != "true" ]]; then
        fail d "cannot validate the PR's file list — plan-doc evidence is unprovable (row validation failed, or the list did not match the PR's file count)."
        echo "      Missing: a validatable diff list."
        echo "      Invoke:  re-run the gate. A path containing a newline or tab, or a truncated response, makes the list unparseable; the same message appears if the list does not match the PR's file count."
      else
        fail d "no plan doc for issue $issue_display (complexity:standard/complex) — the PR must add/modify a file under docs/plans/*.md, or the scoping comment must contain a \"Wiring\" section."
        echo "      Missing: plan doc (docs/plans/*.md) or wiring-check table in scoping comment."
        echo "      Invoke:  writing-plans — it writes the plan doc; issue-scoping adds the Wiring table."
      fi
    else
      echo "ℹ️  [d] Skipped: issue $issue_display has no complexity:standard/complex label — plan doc not required."
    fi

    # e. TEST-COVERAGE EVIDENCE — code-review Step 0. PRs touching runtime
    # code (extensions/**/*.ts excluding *.test.ts, plus extensions/**/*.js
    # and bin/*.js) must show EITHER test file changes in the diff
    # (*.test.ts / *.test.js added or modified, any path) OR explicit
    # test-run markers in the PR body / commit messages. PRs whose diff is
    # only docs/skills/templates/config (no runtime code) are exempt.
    runtime_file="$(printf '%s\n' "$files_plain" | grep -E '^(extensions/.*\.(ts|js)|bin/.*\.js)$' | grep -vE '\.test\.(ts|js)$' | head -1 || true)"
    if [[ "$files_ok" != "true" ]]; then
      # An unvalidatable diff list must FAIL check (e), not skip it. Skipping
      # reads as "this PR changes no runtime code", which is exactly what a
      # forged/truncated list wants — a runtime PR could pass by including a
      # filename with a newline. We cannot prove absence of runtime code, so
      # the evidence is unprovable.
      fail e "cannot validate the PR's file list — test-coverage evidence is unprovable (row validation failed, or the list did not match the PR's file count)."
      echo "      Missing: a validatable diff list."
      echo "      Invoke:  re-run the gate. A path containing a newline or tab, or a truncated response, makes the list unparseable; the same message appears if the list does not match the PR's file count."
    elif [[ -z "$runtime_file" ]]; then
      echo "ℹ️  [e] Skipped: no runtime code changes (extensions/**/*.ts|js, bin/*.js) in this PR."
    else
      test_evidence="$(printf '%s\n' "$files_valid" | LC_ALL=C awk -F '\t' '$1 == "added" || $1 == "modified" { print $2 }' | grep -E '\.test\.(ts|js)$' | head -1 || true)"
      if [[ -n "$test_evidence" ]]; then
        pass e "test coverage evidence: test file change in diff ($test_evidence)"
      elif printf '%s\n%s\n' "$PR_BODY" "$COMMIT_MSGS" | grep -qiE 'tests[[:space:]]+green|[0-9]+[[:space:]]+passed|[0-9]+/[0-9]+|VGATE[[:space:]]+PASS|test[[:space:]]+suite|pytest|npm[[:space:]]+test|vitest'; then
        pass e "test coverage evidence: test-run markers in PR body/commits"
      else
        fail e "no test coverage evidence — this PR changes runtime code ($runtime_file) but shows no sign that tests were run."
        echo "      Accepts: new/updated *.test.ts / *.test.js files in the diff, or markers in PR body/commits (tests green, N passed, N/N, VGATE PASS, test suite, pytest, npm test, vitest)."
        echo "      Missing: test run evidence for the changed runtime code."
        echo "      Invoke:  code-review (Step 0 — test coverage) — run the tests and record evidence in a commit message / the PR body; test-writing adds the missing tests."
      fi
    fi
    echo ""
  fi

  # f. SECOND-MODEL GATE (#716) — required whenever the diff touches the
  # guarded surface (the designation config, its guard script, the runtime
  # dispatch authority, setup/sync, the CI workflow that enables enforcement,
  # the four second-model gate skills, AGENTS.md / the base template,
  # docs/providers.md, record-review.sh, or this script). Tier-independent: a
  # micro PR that changes the gate machinery still owes the recorded gate line.
  # The ONE exemption is the bootstrap carve-out in second_model_base_state().
  # The match runs against BOTH ends of a rename (C2).
  sm_surface="$(printf '%s\n' "$files_ends" "$files_plain" | grep -E "$GUARDED_SURFACE_RE" | head -1 || true)"
  sm_base_state="$(second_model_base_state)"
  if [[ "$files_ok" != "true" ]]; then
    # G4: an unvalidatable file list (a malformed row, or a distinct-path
    # count contradicting the PR's authoritative .changed_files) makes the
    # guarded-surface test unprovable. Checks (d)/(e) already fail closed on
    # this; (f) must not read the empty surface as "not guarded" and skip.
    fail f "cannot validate the PR's file list — the guarded-surface test is unprovable (fail closed). A malformed row or a distinct-path count that contradicts the PR's authoritative .changed_files makes the untrusted diff list untrustworthy, so check (f) cannot prove the second-model guarded surface was untouched."
    echo "      Missing: a well-formed file list whose distinct paths equal .changed_files."
  elif [[ -z "$sm_surface" ]]; then
    echo "ℹ️  [f] Skipped: this PR does not touch the second-model guarded surface."
  elif [[ "$sm_base_state" == "unresolvable" ]]; then
    # C1: fail CLOSED. A base we cannot resolve cannot positively prove the
    # designation file was ever absent, so the bootstrap exemption cannot
    # apply. A WARN here would let a deleted workflow base-fetch step (or a
    # shallow checkout) disable the only merge-blocking second-model check.
    fail f "cannot resolve the PR's base ref — check (f) cannot prove pi-bootstrap/pi-config/second-model.json was absent on base, so the bootstrap exemption does not apply (fail closed). CI must fetch the PR's base commit (GITHUB_BASE_SHA); an unresolvable base on a guarded-surface diff is a FAIL, never a WARN."
    echo "      Missing: a resolvable PR base ref."
    echo "      Invoke:  ensure .github/workflows/pipeline-compliance.yml fetches github.event.pull_request.base.sha, or run from a full clone."
  elif [[ "$sm_base_state" == "absent" ]]; then
    echo ""
    echo "  ⚠️  WARN [f] bootstrap: gate not yet installed on base — enforcing from the next diff that touches the guarded surface"
    echo "      (pi-bootstrap/pi-config/second-model.json is POSITIVELY absent on the PR's BASE ref. This is a one-time"
    echo "       bootstrap exemption keyed ONLY on the file's absence on base — it cannot be obtained by touching"
    echo "       the file, nor keyed on a branch name, PR number, or commit range. Once the file exists on base,"
    echo "       check (f) is unconditional.)"
    echo ""
  else
    sm_line_raw="$(printf '%s\n%s\n' "$PR_BODY" "$COMMIT_MSGS" | grep -E '\[SECOND-MODEL-GATE\]' || true)"
    if [[ -z "$sm_line_raw" ]]; then
      fail f "no [SECOND-MODEL-GATE] line on a diff touching the guarded surface ($sm_surface) — the PR body must record \"[SECOND-MODEL-GATE] model=<resolved provider/id> independent=<yes|NO|DEGRADED> @ <head-sha>\"."
      echo "      Missing: the recorded second-model gate line."
      echo "      Invoke:  the second-model gate — resolve with scripts/check-second-model.sh --print / --probe, then record it (record-review.sh with SECOND_MODEL_GATE_MODEL / SECOND_MODEL_GATE_INDEPENDENT)."
    else
      # G10: collect EVERY marker, never `tail -1`. A later `independent=yes`
      # must not override an earlier honest `independent=DEGRADED` (commit
      # messages sort after the body), and two distinct model ids must not
      # resolve green by keeping the last line.
      sm_malformed="" sm_pairs=""
      while IFS= read -r sm_line; do
        [ -z "$sm_line" ] && continue
        # H6: a line that QUOTES the marker contract is documentation, not a
        # malformed record. Skip it when the `independent` slot is an
        # angle-bracketed/alternation placeholder (`<yes|NO|DEGRADED>`) or the
        # `model` slot is a placeholder (a bracketed value containing `/` —
        # `<resolved provider/id>`). A bare `model=<script>` is NOT a
        # placeholder: genuine garbage must still fail (C3(a) case 6n).
        # I2: classify the SLOTS in isolation. The old test scanned the whole
        # line tail for `|`, so a `|` ANYWHERE after `model=` — an ordinary
        # markdown table cell, or trailing prose like `note kimi|opus` —
        # skipped the line and defeated the conflict / reserved / non-id
        # checks below (`model=none| independent=DEGRADED` was skipped too).
        if [[ "$sm_line" == *"[SECOND-MODEL-GATE]"* ]]; then
          sm_tail="${sm_line#*\[SECOND-MODEL-GATE\]}"
          sm_islot="" sm_mslot=""
          if [[ "$sm_tail" == *"independent="* ]]; then
            sm_islot="${sm_tail#*independent=}"
            sm_islot="${sm_islot%%[[:space:]]*}"
          fi
          if [[ "$sm_tail" == *"model="* ]]; then
            sm_mslot="${sm_tail#*model=}"
            sm_mslot="${sm_mslot%%[[:space:]]*}"
          fi
          # I3: skip a QUOTED PLACEHOLDER only — an explicit allowlist, never a
          # blanket "starts with <" test. A blanket test swallowed the C3(a)
          # non-id control (`model=<script>` must still fail as a non-model
          # value), and the earlier `|`-in-slot test let a genuine conflicting
          # line (`independent=DEGRADED|`, or a markdown table cell) be skipped,
          # defeating the conflict check. Both slots must be RECOGNISED
          # placeholders to skip; anything else falls through and fails closed.
          # `sm_mslot` is whitespace-truncated, so `model=<resolved provider/id>`
          # arrives as `<resolved` — the stem is compared after stripping `<>`.
          sm_ph="${sm_mslot%>}"; sm_ph="${sm_ph#<}"

          case "$sm_ph" in
            id|model|model-id|provider|provider/id|resolved|resolved-provider/id|head-sha|head|sha) continue ;;
          esac
          # The INDEPENDENT slot needs only the angle-bracket test: a real value
          # (`yes`/`NO`/`DEGRADED`) never starts with `<`, so this skips exactly
          # the quoted alternation `independent=<yes|NO|DEGRADED>`. Never list the
          # bare values here — that would skip a genuine marker and make check
          # (f) report `recorded <none>`.
          case "$sm_islot" in "<"*) continue ;; esac
        fi
        # H5: exactly ONE `independent=` token per line. A duplicated token
        # (`independent=yes independent=NO`) would let the FIRST value win —
        # the line must be malformed, never silently read as `yes`.
        if [[ "$sm_line" =~ independent=.*independent= ]]; then
          [ -n "$sm_malformed" ] || sm_malformed="$sm_line"
          continue
        fi
        # H5: the value must be the WHOLE token. The old `([^A-Za-z]|$)`
        # boundary rejected only ALPHABETIC suffixes, so `independent=yes1`,
        # `yes-foo`, `yes_foo` and `yes.` all passed the gate. `($|[[:space:]])`
        # requires a real token boundary.
        if [[ "$sm_line" =~ \[SECOND-MODEL-GATE\][[:space:]]+model=([^[:space:]]+)[[:space:]]+independent=(yes|NO|DEGRADED)($|[[:space:]]) ]]; then
          sm_pairs+="${BASH_REMATCH[1]}"$'\t'"${BASH_REMATCH[2]}"$'\n'
        elif [[ -z "$sm_malformed" ]]; then
          sm_malformed="$sm_line"
        fi
      done <<< "$sm_line_raw"
      if [[ -n "$sm_malformed" ]]; then
        # C3(b)/H5: the value must be the whole token — the boundary group
        # rejects every suffixed value (`independent=yesx`, `yes1`, `yes-foo`,
        # `yes_foo`, `yes.`).
        fail f "malformed [SECOND-MODEL-GATE] line — expected \"[SECOND-MODEL-GATE] model=<provider/id> independent=<yes|NO|DEGRADED> @ <40-hex head-sha>\", got: $(printf '%s' "$sm_malformed" | head -c 200)"
      else
        # C3(a)/G5: a reserved/placeholder model value is never a resolved id,
        # on ANY line. C3(a)/G5: a non-parseable id likewise.
        sm_reserved="" sm_nonid="" sm_badindep=""
        while IFS=$'\t' read -r sm_m sm_i; do
          [ -z "$sm_m" ] && continue
          sm_m_lc="$(printf '%s' "$sm_m" | tr 'A-Z' 'a-z')"
          if [[ "$sm_m_lc" =~ ^(\**degraded|none|null|n/?a|unknown)$ ]]; then
            [ -n "$sm_reserved" ] || sm_reserved="$sm_m"
          elif [[ ! "$sm_m" =~ ^~?[A-Za-z0-9][A-Za-z0-9._-]*(/[A-Za-z0-9][A-Za-z0-9._-]*)*(:[A-Za-z0-9._-]+)?$ ]]; then
            [ -n "$sm_nonid" ] || sm_nonid="$sm_m"
          fi
          if [[ "$sm_i" == "NO" || "$sm_i" == "DEGRADED" ]]; then
            [ -n "$sm_badindep" ] || sm_badindep="$sm_i"
          fi
        done <<< "$sm_pairs"
        sm_distinct="$(printf '%s\n' "$sm_pairs" | sed '/^$/d' | LC_ALL=C sort -u)"
        sm_ndistinct="$(printf '%s\n' "$sm_distinct" | sed '/^$/d' | wc -l | tr -d ' ')"
        if [[ -n "$sm_reserved" ]]; then
          fail f "second-model gate recorded a reserved model value model=$sm_reserved — a reserved/placeholder value (DEGRADED/none/null/n/a/unknown) is never an independent reviewer; record independent=DEGRADED (no funded model) and fail closed."
        elif [[ -n "$sm_nonid" ]]; then
          fail f "second-model gate recorded a non-model value model=$sm_nonid — expected a provider/id (fail closed)."
        elif [[ "${sm_ndistinct:-0}" -gt 1 ]]; then
          # G10: conflicting markers fail closed. Two distinct model ids, or two
          # distinct independence values, cannot be resolved by preferring the
          # last line.
          fail f "conflicting [SECOND-MODEL-GATE] lines — every marker must record the SAME model and independence value; a later line must not override an earlier one (fail closed). Found: $(printf '%s' "$sm_distinct" | tr '\n' ' ' | head -c 300)"
        elif [[ -n "$sm_badindep" ]]; then
          sm_model="${sm_distinct%%$'\t'*}"
          if [[ "$sm_badindep" == "NO" ]]; then
            fail f "second-model gate recorded independent=NO ($sm_model) — a same-build/stand-in review is not independent; do NOT merge. A DEGRADED/no-funded-model window is a human decision, recorded as independent=DEGRADED — never laundered into a pass."
          else
            fail f "second-model gate recorded independent=DEGRADED ($sm_model) — no solvent+reachable independent model; the merge gate fails closed by design. Get a model funded, or clear the bootstrap window (an operator decision), then re-record."
          fi
        else
          sm_model="${sm_distinct%%$'\t'*}"
          sm_indep="${sm_distinct##*$'\t'}"
          sm_sha=""
          # C3(c): pick the marker line that carries THIS head binding. Every
          # line agrees on model+indep, so a head-bound one proves the record
          # is current.
          while IFS= read -r sm_line; do
            [[ "$sm_line" =~ model=${sm_model}[[:space:]] ]] || continue
            [[ "$sm_line" =~ independent=${sm_indep}($|[[:space:]]) ]] || continue
            if [[ "$sm_line" =~ @[[:space:]]*([0-9a-f]{40})([^0-9a-f]|$) ]]; then
              sm_sha="${BASH_REMATCH[1]}"
            fi
            break
          done <<< "$sm_line_raw"
          if [[ -z "$PR_HEAD_SHA" ]]; then
            fail f "cannot determine the PR head sha — the recorded [SECOND-MODEL-GATE] line cannot be bound to this PR's head (fail closed)."
          elif [[ "$sm_sha" != "$PR_HEAD_SHA" ]]; then
            fail f "the recorded [SECOND-MODEL-GATE] line is not bound to the PR head (recorded ${sm_sha:-<none>}, head $PR_HEAD_SHA) — a marker from another PR or an earlier head must not satisfy check (f) (fail closed)."
          elif [[ ! -f "$SM_GUARD" ]]; then
            fail f "second-model gate line present but the guard script is missing ($SM_GUARD) — cannot verify the recorded id is independent (fail closed)."
          elif sm_equiv "$sm_model" >/dev/null 2>&1; then
            # exit 0 = the recorded id IS in the primary's build-equivalence set
            fail f "the recorded second-model id ($sm_model) is the SAME served build as the primary — a build-equivalent id is not an independent reviewer (record a non-equivalent id; see scripts/check-second-model.sh --print)."
          else
            sm_rc=$?
            if [[ "$sm_rc" -eq 1 ]]; then
              pass f "second-model gate recorded: model=$sm_model independent=$sm_indep (non-build-equivalent to the primary, bound to head $PR_HEAD_SHA)"
            else
              fail f "could not classify the recorded second-model id ($sm_model) with $SM_GUARD (exit $sm_rc) — fail closed."
            fi
          fi
        fi
      fi
    fi
  fi
  echo ""

  return "$FAILURES"
}

summarize() {
  echo ""
  if [[ "$FAILURES" -gt 0 ]]; then
    echo "❌ PIPELINE COMPLIANCE: BLOCKED ($FAILURES failure(s))."
    echo "   Fix the items above, then re-run. Each failure names the missing artifact and the skill that produces it."
    return 1
  fi
  echo "✅ PIPELINE COMPLIANCE: PASS — scoping/review/plan/test evidence present."
  return 0
}

# ── Dry-run plan (no gh calls) ──────────────────────────────────────────────
if [[ "$DRY_RUN" == "1" && "$FAIL_ALL" != "1" ]]; then
  echo "=== Pipeline Compliance Gate (DRY RUN — no gh calls) ==="
  echo "PR:   $GH_REPO#$PR_NUMBER"
  echo ""
  echo "Would check, in order:"
  echo "  a. LINKED ISSUE      gh api repos/$GH_REPO/pulls/$PR_NUMBER   → parse PR body for closing keywords (Fixes/Closes/Resolves #N, owner/repo#N, or full https://github.com/owner/repo/issues/N URL); a PR whose diff is ENTIRELY under docs/ may instead use a traceability keyword (Refs/Part of/Advances/Tracks/Relates to #N) — closure is not implied"
  echo "                      labels + scoping comments are fetched from the issue's OWN repo when it differs from $GH_REPO (cross-repo)"
  echo "  b. SCOPING COMMENT   gh api repos/$GH_REPO/issues/<n>/comments → search for '<!-- issue-scoping:' marker"
  echo "  c. CODE-REVIEW EVID  gh api repos/$GH_REPO/pulls/$PR_NUMBER/commits + PR body → search review markers (code-review, reviewer, [review], VGATE, review recorded, review-enforcer)"
  echo "  d. PLAN DOC          gh api repos/$GH_REPO/pulls/$PR_NUMBER/files → docs/plans/*.md change, or 'Wiring' in scoping comment (complexity:standard/complex only)"
  echo "  e. TEST-COVERAGE EVID gh api repos/$GH_REPO/pulls/$PR_NUMBER/files → runtime code changes (extensions/**/*.ts excl. *.test.ts, extensions/**/*.js, bin/*.js) need test files in the diff or test-run markers in PR body/commits"
  echo "  f. SECOND-MODEL GATE  PR body/commits must carry '[SECOND-MODEL-GATE] model=<id> independent=<yes|NO|DEGRADED>' when the diff touches the guarded surface; NO/DEGRADED and a build-equivalent id FAIL (one bootstrap WARN while the base lacks pi-bootstrap/pi-config/second-model.json)"
  echo ""
  echo "Exemptions: complexity:micro label skips b–e; no standard/complex label skips d; docs/skills/templates/config-only PRs (no runtime code) skip e; check (f) is tier-independent with a one-time bootstrap WARN."
  echo "Exit: 0 (compliant, simulated)."
  echo "For failure-path simulation: PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1"
  echo "For parser-only self-test (no gh calls): PIPELINE_COMPLIANCE_SELF_TEST=1"
  exit 0
fi

# ── Failure simulation (offline test of failure output paths) ───────────────
if [[ "$FAIL_ALL" == "1" ]]; then
  # Pass 1: no linked issue → a fails, b–e skipped.
  echo "== SIMULATION: all-failures pass 1 of 5 (no linked issue) =="
  PR_BODY=""; LABELS=""; SCOPING_COMMENT=""; COMMIT_MSGS=""; FILES=""
  FAILURES=0
  run_checks || true
  summarize || true

  # Pass 2: standard/complex issue, all evidence missing → a passes (keyword
  # parser exercised), b/c/d/e fail. FILES includes a runtime-code change so
  # check e runs (and fails) rather than being skipped.
  echo ""
  echo "== SIMULATION: all-failures pass 2 of 5 (standard/complex issue, no evidence) =="
  PR_BODY="Fixes #1"; LABELS="complexity:standard"; SCOPING_COMMENT=""; COMMIT_MSGS=""
  FILES=$'added\textensions/example/sample.ts\t'
  FILES_EXPECTED=1
  FAILURES=0
  run_checks || true
  summarize || true

  # Pass 3: cross-repo issue reference. parse_issue_ref must resolve the
  # issue's OWN repo (daniel-ospina/swarm), not GH_REPO — the gate then
  # fetches labels/comments from repos/daniel-ospina/swarm/issues/2492.
  # Assert the parse directly (pure shell, no gh) and exercise run_checks
  # with the cross-repo body (a passes and displays the full owner/repo#N ref).
  echo ""
  echo "== SIMULATION: pass 3 of 5 (cross-repo issue reference) =="
  ref="$(parse_issue_ref 'Fixes daniel-ospina/swarm#2492')"
  [[ "$ref" == "daniel-ospina/swarm#2492" ]] || { echo "❌ SELF-TEST FAIL: parse_issue_ref('Fixes daniel-ospina/swarm#2492') = '$ref', expected 'daniel-ospina/swarm#2492'." >&2; exit 2; }
  ref="$(parse_issue_ref 'Closes https://github.com/daniel-ospina/swarm/issues/2492')"
  [[ "$ref" == "daniel-ospina/swarm#2492" ]] || { echo "❌ SELF-TEST FAIL: full-URL parse = '$ref', expected 'daniel-ospina/swarm#2492'." >&2; exit 2; }
  # Host-axis casing (#513 review r3): GitHub identity is case-insensitive on
  # the HOST too — an uppercase-host URL must resolve, not drop to arm (c).
  ref="$(parse_issue_ref 'Closes https://GITHUB.com/Daniel-Ospina/Agent-Infra/issues/2492')"
  [[ "$ref" == "daniel-ospina/agent-infra#2492" ]] || { echo "❌ SELF-TEST FAIL: mixed-case-host URL parse = '$ref', expected 'daniel-ospina/agent-infra#2492'." >&2; exit 2; }
  ref="$(parse_issue_ref 'Resolves https://github.com/daniel-ospina/agent-infra/pull/171')"
  [[ -z "$ref" ]] || { echo "❌ SELF-TEST FAIL: pull-request URL must NOT parse as an issue, got '$ref'." >&2; exit 2; }
  ref="$(parse_issue_ref 'Fixes #7')"
  [[ "$ref" == "$GH_REPO#7" ]] || { echo "❌ SELF-TEST FAIL: bare #N parse = '$ref', expected '$GH_REPO#7'." >&2; exit 2; }
  # Regression: a non-issue token after a closing keyword must not shadow a
  # real ref later in the text (PR #171's body: "resolves SLACK_APPROVAL_FILE … Closes #2492").
  ref="$(parse_issue_ref 'resolves SLACK_APPROVAL_FILE first, then Closes #2492')"
  [[ "$ref" == "$GH_REPO#2492" ]] || { echo "❌ SELF-TEST FAIL: keyword + non-issue token shadowing = '$ref', expected '$GH_REPO#2492'." >&2; exit 2; }
  PR_BODY="Fixes daniel-ospina/swarm#2492"; LABELS="complexity:standard"; SCOPING_COMMENT=""; COMMIT_MSGS=""
  FILES=$'added\textensions/example/sample.ts\t'
  FILES_EXPECTED=1
  FAILURES=0
  run_checks || true
  summarize || true

  # Pass 4 (#513): #513 verdict-tier binding — a NON-micro issue whose
  # body/commits claim verdict=clean-micro (the record-review.sh marker text)
  # must FAIL check (c) with the binding message, even though the generic
  # evidence grep matches the marker. RED pre-#513 (the generic grep passed
  # the marker); GREEN post-binding. FAILURES alone is NOT discriminating
  # here (checks b/d/e also fail in this scenario) — assert the binding
  # message text in check (c)'s output.
  echo ""
  echo "== SIMULATION: pass 4 of 5 (#513 binding: clean-micro marker on a standard issue fails c) =="
  PR_BODY="Fixes #1"; LABELS="complexity:standard"; SCOPING_COMMENT=""
  COMMIT_MSGS="review recorded: reviews/1.json verdict=clean-micro @ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (daniel-ospina/agent-infra)"
  FILES=$'added\textensions/example/sample.ts\t'
  FILES_EXPECTED=1
  FAILURES=0
  P4LOG="$(mktemp /tmp/pipeline-pass4.XXXXXX)"
  run_checks > "$P4LOG" 2>&1 || true
  cat "$P4LOG"
  B4="$FAILURES"
  if [[ "$B4" -ge 1 ]] && grep -q 'clean-micro verdict marker' "$P4LOG"; then
    echo "  ✅ pass 4: binding fired — check (c) named the clean-micro marker on the standard issue"
    rm -f "$P4LOG"
  else
    echo "  ❌ pass 4: binding did NOT fire — clean-micro marker passed check (c) on a standard issue (failures=$B4)" >&2
    rm -f "$P4LOG"
    exit 2
  fi
  summarize || true

  # Pass 4b (#513 regression pin — self-review catch): a NON-micro PR whose
  # body/commits merely MENTION "verdict=clean-micro" in prose (describing the
  # marker contract, e.g. this PR's own description) must NOT trip the binding
  # — only the record-review.sh marker shape (verdict=… @ <40-hex sha>) is a
  # real certification. RED pre-tightening (bare-substring grep matched the
  # prose); GREEN now.
  echo ""
  echo "== SIMULATION: pass 4b (#513 binding precision: prose mention must NOT fire) =="
  PR_BODY="Fixes #1"; LABELS="complexity:standard"; SCOPING_COMMENT=""
  COMMIT_MSGS="code-review dispatched; the binding rejects body/commits claiming verdict=clean-micro (marker shape only)"
  FILES=$'added\textensions/example/sample.ts\t'
  FILES_EXPECTED=1
  FAILURES=0
  P4BLOG="$(mktemp /tmp/pipeline-pass4b.XXXXXX)"
  run_checks > "$P4BLOG" 2>&1 || true
  if grep -q 'clean-micro verdict marker' "$P4BLOG"; then
    echo "  ❌ pass 4b: prose mention fired the binding — check (c) must match only the marker shape (verdict=… @ <40-hex>)" >&2
    rm -f "$P4BLOG"
    exit 2
  else
    echo "  ✅ pass 4b: prose mention did NOT fire — binding precision holds"
    rm -f "$P4BLOG"
  fi
  summarize || true

  # Pass 5 (#513): micro-exemption pin — a MICRO issue with the same
  # clean-micro marker must produce ZERO failures (a passes; b–e skipped by
  # the micro exemption; the binding must never leak into the micro branch).
  # Green pre- AND post-#513 by design — a placement-leak guard, not evidence
  # the binding exists (pass 4 carries that proof).
  echo ""
  echo "== SIMULATION: pass 5 of 5 (#513 micro exemption: clean-micro marker on a micro issue → 0 failures) =="
  PR_BODY="Fixes #1"; LABELS="complexity:micro"; SCOPING_COMMENT=""
  COMMIT_MSGS="review recorded: reviews/1.json verdict=clean-micro @ aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa (daniel-ospina/agent-infra)"
  FILES=$'added\tdocs/plans/2026-09-06-issue-513-clean-micro-verdict.md\t'
  FILES_EXPECTED=1
  FAILURES=0
  run_checks || true
  B5="$FAILURES"
  summarize || true
  if [[ "$B5" -eq 0 ]]; then
    echo "  ✅ pass 5: micro exemption held — 0 failures (b–e skipped, binding did not leak)"
  else
    echo "  ❌ pass 5: micro exemption violated — binding leaked into the micro branch ($B5 failures)" >&2
    exit 2
  fi

  # Pass 6 (#716) — check (f): the second-model gate line on a guarded-surface
  # diff, plus BOTH sides of the bootstrap exemption. Base content is injected
  # with the documented offline seam PIPELINE_SECOND_MODEL_BASE_FILE (a path, or
  # the literal ABSENT); the real path uses `git show <base>:<path>`.
  echo ""
  echo "== SIMULATION: pass 6 (#716 check (f) — guarded-surface gate line) =="
  SM_SIM_SHIPPED="$(cd "$(dirname "$0")/.." && pwd)/pi-bootstrap/pi-config/second-model.json"
  # A deterministic fake PR head for the offline check (f) cases; the marker
  # must carry it verbatim (C3 head binding).
  SM_SIM_SHA="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  # Pin the guard authority so check (f)'s equivalence call is hermetic and
  # never reads an ambient $HOME config (D2).
  PIPELINE_SECOND_MODEL_LIVE_DIR="$(cd "$(dirname "$0")/.." && pwd)/pi-bootstrap/pi-config"
  # Main's files_rows() requires EXACTLY 3 tab-separated fields per row
  # (status\tpath\tprevpath, trailing tab when there is no previous path) and
  # pins the DISTINCT-new-path count to FILES_EXPECTED. The check (f) cases
  # therefore build 3-field rows and declare their distinct-path count.
  sm_case() { # <tag> <label> <sm-line> <base-file> <want-zero> <needle> [<files> <expected> <labels> <commits>]
    local tag="$1" label="$2" smline="$3" basefile="$4" wantzero="$5" needle="$6" log ok=1
    FILES="${7:-$'modified\tpi-bootstrap/pi-config/second-model.json\t'}"
    FILES_EXPECTED="${8:-1}"
    PR_HEAD_SHA="$SM_SIM_SHA"
    if [[ -n "$smline" ]]; then
      PR_BODY="Fixes #1
${smline}"
    else
      PR_BODY="Fixes #1"
    fi
    LABELS="${9:-complexity:standard}"
    SCOPING_COMMENT="<!-- issue-scoping: simulation --> wiring"
    COMMIT_MSGS="${10:-code-review dispatched; tests green (12 passed)}"
    PIPELINE_SECOND_MODEL_BASE_FILE="$basefile"
    FAILURES=0
    log="$(mktemp /tmp/pipeline-sm6.XXXXXX)"
    run_checks > "$log" 2>&1 || true
    grep -q "$needle" "$log" || ok=0
    if [[ "$wantzero" == "1" ]]; then
      [[ "$FAILURES" -eq 0 ]] || ok=0
    else
      [[ "$FAILURES" -ge 1 ]] || ok=0
    fi
    if [[ "$ok" == "1" ]]; then
      echo "  ✅ pass ${tag}: check (f) ${label}"
    else
      echo "  ❌ pass ${tag}: check (f) ${label} FAILED (failures=$FAILURES)" >&2
      sed -n '1,40p' "$log" >&2
      rm -f "$log"
      exit 2
    fi
    rm -f "$log"
  }
  sm_case 6 "passed (independent, non-equivalent id)" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 1 "second-model gate recorded"
  sm_case 6b "blocked DEGRADED" \
    "[SECOND-MODEL-GATE] model=**DEGRADED independent=DEGRADED @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "independent=DEGRADED"
  sm_case 6c "blocked independent=NO" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=NO @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "independent=NO"
  sm_case 6d "blocked a build-equivalent recorded id" \
    "[SECOND-MODEL-GATE] model=deepseek/deepseek-v4-pro independent=yes @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "SAME served build as the primary"
  # H1: pi's resolver PARTIAL-matches the bare provider shorthand onto a
  # concrete served build (`deepseek` → `deepseek/deepseek-v4-pro`, the
  # primary's served build), so the shorthand must FAIL as build-equivalent —
  # not pass on an exact-id-only equivalence set.
  sm_case 6y "blocks the bare deepseek shorthand as independent=yes" \
    "[SECOND-MODEL-GATE] model=deepseek independent=yes @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "SAME served build as the primary"
  sm_case 6e "blocked a missing marker" \
    "" "$SM_SIM_SHIPPED" 0 "no \[SECOND-MODEL-GATE\] line"
  sm_case 6f "bootstrap exemption WARN" \
    "" "ABSENT" 1 "bootstrap: gate not yet installed on base"
  sm_case 6g "enforcement on once the file exists on base" \
    "" "$SM_SIM_SHIPPED" 0 "no \[SECOND-MODEL-GATE\] line"
  # C1: an UNRESOLVABLE base must FAIL, not WARN. A deleted base-fetch step in
  # the CI workflow (or a shallow clone) must not silently disable check (f).
  sm_case 6h "FAILS on an unresolvable base (deleted base-fetch / shallow clone)" \
    "" "UNRESOLVABLE" 0 "cannot resolve the PR's base ref"
  # C2: a content-identical rename OUT of the guarded surface must still be
  # judged by its previous path.
  sm_case 6i "enforces across a rename OUT of the guarded surface" \
    "" "$SM_SIM_SHIPPED" 0 "no \[SECOND-MODEL-GATE\] line" \
    $'renamed\tscripts/check-second-model.sh.bak\tscripts/check-second-model.sh' 1
  # C2/G11: gate-weakening files that must be part of the guarded surface -
  # including the two workflows that RUN the guard and the fixture suite itself
  # (deleting them removes all post-merge verification with no gate line).
  for gpath in .github/workflows/pipeline-compliance.yml .github/workflows/ci.yml .github/workflows/ci-main.yml tests/second-model/run.sh pi-bootstrap/setup.sh sync.sh pi-bootstrap/pi-config/models.json; do
    sm_case "6p-$(printf '%s' "$gpath" | tr '/.' '__')" "enforces on a change to $gpath" \
      "" "$SM_SIM_SHIPPED" 0 "no \[SECOND-MODEL-GATE\] line" \
      "$(printf 'modified\t%s\t' "$gpath")" 1
  done
  # G4: check (f) must FAIL (not skip) when the PR's file list cannot be
  # validated — a malformed row or a distinct-path count that contradicts
  # .changed_files. A micro PR skips b-e, so this was the ONLY failure path.
  sm_case 6q "FAILS on a malformed file row (micro PR, no b-e)" \
    "" "$SM_SIM_SHIPPED" 0 "cannot validate the PR's file list" \
    $'added\tpi-bootstrap/pi-config/second\nmodel.json\t' 1 "complexity:micro"
  sm_case 6r "FAILS on a FILES_EXPECTED mismatch (micro PR, no b-e)" \
    "" "$SM_SIM_SHIPPED" 0 "cannot validate the PR's file list" \
    $'modified\tpi-bootstrap/pi-config/second-model.json\t' 2 "complexity:micro"
  # G5: reserved/placeholder ids beyond DEGRADED are never a resolved id.
  sm_case 6s "blocks a reserved none-token model laundered as independent=yes" \
    "[SECOND-MODEL-GATE] model=none independent=yes @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "reserved model value"
  sm_case 6t "blocks a reserved null-token model laundered as independent=yes" \
    "[SECOND-MODEL-GATE] model=null independent=yes @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "reserved model value"
  # G10: conflicting markers must fail closed. Body records DEGRADED, a later
  # commit message records yes (the old `tail -1` resolved green).
  sm_case 6u "blocks conflicting markers (later yes must not override DEGRADED)" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=DEGRADED @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "conflicting \[SECOND-MODEL-GATE\] lines" \
    "" 1 "complexity:standard" "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ $SM_SIM_SHA"
  sm_case 6v "blocks two distinct recorded model ids" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "conflicting \[SECOND-MODEL-GATE\] lines" \
    "" 1 "complexity:standard" "[SECOND-MODEL-GATE] model=openrouter/anthropic/claude-opus-4.8 independent=yes @ $SM_SIM_SHA"
  # I2: the H6 placeholder skip tested the WHOLE line tail for `|`, so ANY `|`
  # after `model=` (trailing prose, a markdown table cell, a `none|` value)
  # skipped a genuine marker and defeated the conflict / reserved / non-id
  # checks. The placeholder signal must be read from the model slot ONLY.
  sm_case 6i2 "blocks a conflicting pair whose DEGRADED line has a | in trailing prose" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=DEGRADED @ $SM_SIM_SHA note kimi|opus" "$SM_SIM_SHIPPED" 0 "conflicting \[SECOND-MODEL-GATE\] lines" \
    "" 1 "complexity:standard" "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ $SM_SIM_SHA"
  sm_case 6i3 "blocks a conflicting markdown-table-cell marker (trailing |)" \
    "| [SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=DEGRADED @ $SM_SIM_SHA |" "$SM_SIM_SHIPPED" 0 "conflicting \[SECOND-MODEL-GATE\] lines" \
    "" 1 "complexity:standard" "| [SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ $SM_SIM_SHA |"
  sm_case 6i4 "blocks model=none| (a | in the MODEL slot is not a placeholder)" \
    "[SECOND-MODEL-GATE] model=none| independent=DEGRADED @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "non-model value"
  # C3(a): a reserved model value laundered as independent=yes must FAIL.
  sm_case 6j "blocks a reserved model laundered as independent=yes" \
    "[SECOND-MODEL-GATE] model=**DEGRADED independent=yes @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "reserved model value"
  # C3(a): the bare reserved token, too.
  sm_case 6o "blocks the bare DEGRADED token as a model value" \
    "[SECOND-MODEL-GATE] model=DEGRADED independent=DEGRADED @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "reserved model value"
  # C3(b): the trailing boundary — `independent=yesx` must not match `yes`.
  sm_case 6k "blocks a trailing-boundary bypass (independent=yesx)" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yesx @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "malformed \[SECOND-MODEL-GATE\]"
  # H5: the old boundary `([^A-Za-z]|$)` rejected only ALPHABETIC suffixes, so
  # these all passed the gate. The value must be the whole token.
  sm_case 6k1 "blocks a numeric-suffixed boundary bypass (independent=yes1)" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes1 @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "malformed \[SECOND-MODEL-GATE\]"
  sm_case 6k2 "blocks a hyphen-suffixed boundary bypass (independent=yes-foo)" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes-foo @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "malformed \[SECOND-MODEL-GATE\]"
  sm_case 6k3 "blocks an underscore-suffixed boundary bypass (independent=yes_foo)" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes_foo @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "malformed \[SECOND-MODEL-GATE\]"
  sm_case 6k5 "blocks a punctuation-suffixed boundary bypass (independent=yes.)" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes. @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "malformed \[SECOND-MODEL-GATE\]"
  # H5: a duplicated `independent=` token must not let the first value win.
  sm_case 6k4 "blocks a duplicated independent= token" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes independent=NO @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "malformed \[SECOND-MODEL-GATE\]"
  # H6: a PR body that QUOTES the required format (placeholders in <…>, an
  # alternation) must still pass its own gate when a valid marker is present.
  sm_case 6z "passes when the body quotes the marker format alongside a valid marker" \
    $'[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ '"$SM_SIM_SHA"$'\nThe contract is `[SECOND-MODEL-GATE] model=<resolved provider/id> independent=<yes|NO|DEGRADED> @ <head-sha>`.' \
    "$SM_SIM_SHIPPED" 1 "second-model gate recorded"
  # H6: genuine garbage is still malformed (the quoting skip must not swallow it).
  sm_case 6z2 "FAILS on a genuine garbage marker line" \
    "[SECOND-MODEL-GATE] this is not a marker at all" "$SM_SIM_SHIPPED" 0 "malformed \[SECOND-MODEL-GATE\]"
  # I3: 6z above passes via the ISLOT arm (its quoted line carries
  # `independent=<yes|NO|DEGRADED>`, and `|` no longer triggers the skip — it
  # passes because the islot is angle-bracketed). This case is the one that
  # actually pins the MODEL-slot arm: the quoted line carries an
  # angle-bracketed model placeholder AND a concrete `independent=yes` (no
  # `|`, no `<` in the islot). It is the exact documented success form from
  # AGENTS.md / the base template / providers.md / the four skills, so a PR
  # that quotes the contract as written must still pass its own gate.
  # NOTE: `model=<resolved provider/id>` truncates the slot at the internal
  # space to `<resolved`, which also starts with `<` — covered by 6z3b.
  sm_case 6z3 "passes when the body quotes `model=<id> independent=yes`" \
    $'[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ '"$SM_SIM_SHA"$'\nRecord it as `[SECOND-MODEL-GATE] model=<id> independent=yes @ <head-sha>`.' \
    "$SM_SIM_SHIPPED" 1 "second-model gate recorded"
  sm_case 6z3b "passes when the body quotes `model=<resolved provider/id>`" \
    $'[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ '"$SM_SIM_SHA"$'\nRecord it as `[SECOND-MODEL-GATE] model=<resolved provider/id> independent=yes @ <head-sha>`.' \
    "$SM_SIM_SHIPPED" 1 "second-model gate recorded"
  # Pins the INDEPENDENT-slot arm specifically: a line that DOES carry the
  # marker token and a CONCRETE model, with only the independence value quoted.
  # Without that arm this line reads as malformed and blocks a PR that
  # documents the contract. (The quoting line must contain the marker token,
  # or the placeholder block is never reached at all.)
  sm_case 6z4 "passes when a quoted line has a concrete model + quoted independent" \
    $'[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ '"$SM_SIM_SHA"$'\nThe value is `[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=<yes|NO|DEGRADED> @ <head-sha>`.' \
    "$SM_SIM_SHIPPED" 1 "second-model gate recorded"
  # I3 residual: a pipe GLUED to a real independence value (`DEGRADED|`) must
  # NOT be read as a placeholder — otherwise the conflict check is defeated by
  # a narrower spelling of the I2 fail-open. The line is either malformed or
  # conflicting; either way the gate must FAIL with an honest DEGRADED present.
  sm_case 6i5 "blocks a glued-pipe DEGRADED line (| in the INDEPENDENT slot)" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=DEGRADED| @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "\[SECOND-MODEL-GATE\]" \
    "" 1 "complexity:standard" "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ $SM_SIM_SHA"
  # C3(c): the line must be bound to the PR head.
  sm_case 6l "blocks a marker bound to another head" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes @ 1111111111111111111111111111111111111111" "$SM_SIM_SHIPPED" 0 "not bound to the PR head"
  sm_case 6m "blocks a marker with no head binding" \
    "[SECOND-MODEL-GATE] model=moonshot/kimi-k3 independent=yes" "$SM_SIM_SHIPPED" 0 "not bound to the PR head"
  # C3: a non-id model value is never a resolved id.
  sm_case 6n "blocks a non-id model value" \
    "[SECOND-MODEL-GATE] model=<script> independent=yes @ $SM_SIM_SHA" "$SM_SIM_SHIPPED" 0 "non-model value"
  # G3: the REAL git path (NOT the PIPELINE_SECOND_MODEL_BASE_FILE seam).
  # `git rev-parse --verify --quiet <40-hex>` is vacuously rc=0 for a
  # well-formed but ABSENT sha, so the pre-fix guard reported "absent" and
  # check (f) took the bootstrap WARN forever. Opt-in so the ambient FAIL_ALL
  # stays deterministic (it depends on origin/main/HEAD^ content);
  # tests/second-model/run.sh drives these from a temp git repo whose main
  # carries the designation and whose origin/main / HEAD^ do not.
  if [[ "${PIPELINE_SECOND_MODEL_GIT_CASES:-0}" == "1" ]]; then
    SM_ABSENT_SHA="deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"
    sm_git_case() { # <tag> <label> <base-sha> <base-ref>
      local tag="$1" label="$2" base_sha="$3" base_ref="$4" log ok=1
      PR_BODY="Fixes #1"; LABELS="complexity:standard"
      SCOPING_COMMENT="<!-- issue-scoping: simulation --> wiring"
      COMMIT_MSGS="code-review dispatched; tests green (12 passed)"
      FILES=$'modified\tpi-bootstrap/pi-config/second-model.json\t'; FILES_EXPECTED=1
      PR_HEAD_SHA="$SM_SIM_SHA"
      unset PIPELINE_SECOND_MODEL_BASE_FILE GITHUB_BASE_SHA PIPELINE_BASE_REF GITHUB_BASE_REF
      [ -n "$base_sha" ] && export GITHUB_BASE_SHA="$base_sha"
      [ -n "$base_ref" ] && export PIPELINE_BASE_REF="$base_ref"
      FAILURES=0
      log="$(mktemp /tmp/pipeline-smgit.XXXXXX)"
      run_checks > "$log" 2>&1 || true
      grep -q "cannot resolve the PR's base ref" "$log" || ok=0
      [[ "$FAILURES" -ge 1 ]] || ok=0
      unset GITHUB_BASE_SHA PIPELINE_BASE_REF
      if [[ "$ok" == "1" ]]; then
        echo "  ✅ pass ${tag}: check (f) ${label}"
      else
        echo "  ❌ pass ${tag}: check (f) ${label} FAILED (failures=$FAILURES) — a vacuous git existence guard let the bootstrap WARN fire" >&2
        sed -n '1,40p' "$log" >&2
        rm -f "$log"
        exit 2
      fi
      rm -f "$log"
    }
    sm_git_case 6w "FAILS on an absent-but-well-formed real GITHUB_BASE_SHA (real git path)" "$SM_ABSENT_SHA" ""
    sm_git_case 6x "FAILS when a raw-sha PIPELINE_BASE_REF is absent and a fallback ref resolves but lacks the file" "" "$SM_ABSENT_SHA"
  fi
  unset PIPELINE_SECOND_MODEL_BASE_FILE PIPELINE_SECOND_MODEL_LIVE_DIR PR_HEAD_SHA
  exit 1
fi

# ── Parser self-test (pure shell, no gh calls) ─────────────────────────────
# PIPELINE_COMPLIANCE_SELF_TEST=1 runs assertions against parse_issue_ref and
# exits 0 on success / 2 on failure. Also exercised inside FAIL_ALL (pass 3).
if [[ "${PIPELINE_COMPLIANCE_SELF_TEST:-0}" == "1" ]]; then
  echo "=== Pipeline Compliance — parse_issue_ref self-test (no gh calls) ==="
  selffail=0
  expect_ref() {
    local input="$1" expected="$2" got
    got="$(parse_issue_ref "$input")"
    if [[ "$got" == "$expected" ]]; then
      printf '✅ parse_issue_ref(%q) → %q\n' "$input" "$got"
    else
      printf '❌ parse_issue_ref(%q) → %q (expected %q)\n' "$input" "$got" "$expected" >&2
      selffail=$((selffail + 1))
    fi
  }
  expect_ref 'Fixes daniel-ospina/swarm#2492' 'daniel-ospina/swarm#2492'
  expect_ref 'Closes https://github.com/daniel-ospina/swarm/issues/2492' 'daniel-ospina/swarm#2492'
  expect_ref 'Closes https://GITHUB.com/Daniel-Ospina/Agent-Infra/issues/2492' 'daniel-ospina/agent-infra#2492'
  expect_ref 'Resolves #7' "$GH_REPO#7"
  expect_ref 'FIXES #9' "$GH_REPO#9"
  expect_ref 'Fixes https://github.com/daniel-ospina/agent-infra/pull/171' ''
  expect_ref 'Fixes #173, Closes #174' "$GH_REPO#173"
  expect_ref 'This fixes #42 in passing' "$GH_REPO#42"
  expect_ref 'resolves SLACK_APPROVAL_FILE first, then Closes #2492' "$GH_REPO#2492"
  expect_ref 'Closes #173.' "$GH_REPO#173"
  expect_ref 'No issue referenced here' ''

  # ── #720: closing parser must NOT accept traceability keywords ────────────
  # These are the RED-if-broken assertions for the docs-only fallback. If
  # parse_issue_ref ever matches "Refs/Part of/...", check (a) could be
  # satisfied on a CODE PR without closing any issue — the weakening this
  # design exists to prevent.
  expect_ref 'Refs #631' ''
  expect_ref 'Part of #631' ''
  expect_ref 'Advances #631' ''
  expect_ref 'Relates to #631' ''
  # A non-issue token after a trace keyword must not shadow a real ref (the
  # same shadowing regression class as the SLACK_APPROVAL_FILE case above).
  expect_ref 'Part of the fleet, Refs #631' ''

  expect_trace() {
    local input="$1" expected="$2" got
    got="$(parse_trace_ref "$input")"
    if [[ "$got" == "$expected" ]]; then
      printf '✅ parse_trace_ref(%q) → %q\n' "$input" "$got"
    else
      printf '❌ parse_trace_ref(%q) → %q (expected %q)\n' "$input" "$got" "$expected" >&2
      selffail=$((selffail + 1))
    fi
  }
  expect_trace 'Refs #631' "$GH_REPO#631"
  expect_trace 'Part of #631' "$GH_REPO#631"
  expect_trace 'Advances #631' "$GH_REPO#631"
  expect_trace 'Tracks #631' "$GH_REPO#631"
  expect_trace 'Relates to #631' "$GH_REPO#631"
  expect_trace 'Refs daniel-ospina/swarm#2492' 'daniel-ospina/swarm#2492'
  expect_trace 'Refs https://github.com/daniel-ospina/swarm/issues/2492' 'daniel-ospina/swarm#2492'
  # Closure vocabulary belongs to the closing parser, not this one.
  expect_trace 'Closes #631' ''
  expect_trace 'No issue referenced here' ''
  expect_trace 'Part of the fleet' ''

  # ── #720: docs-only gate + combined resolution ──────────────────────────
  expect_docs_only() {
    local desc="$1" files="$2" want="$3" expected="${4:-}" got rc=0
    FILES_EXPECTED="$expected"
    pr_is_docs_only "$files" || rc=$?
    FILES_EXPECTED=""
    [[ "$want" == "true" ]] && want=0 || want=1
    if [[ "$rc" == "$want" ]]; then
      printf '✅ pr_is_docs_only(%s) → %s\n' "$desc" "$([[ $rc == 0 ]] && echo true || echo false)"
    else
      printf '❌ pr_is_docs_only(%s) → rc=%s (expected %s)\n' "$desc" "$rc" "$want" >&2
      selffail=$((selffail + 1))
    fi
  }
  expect_docs_only 'docs only' $'added\tdocs/plans/x.md\t\nmodified\tdocs/research/y.md\t' true
  expect_docs_only 'docs + code' $'added\tdocs/plans/x.md\t\nmodified\tscripts/z.sh\t' false
  expect_docs_only 'code only' $'modified\tAGENTS.md\t' false
  expect_docs_only 'skills only' $'modified\tskills/foo/SKILL.md\t' false
  # Empty/unreadable file list must NOT unlock the fallback (fails closed).
  expect_docs_only 'empty list' '' false
  expect_docs_only 'status-only row' $'added' false
  # Fail-closed tripwires (VGATE #720). A filename containing a newline or tab
  # breaks the row framing; an EMPTY filename can vanish when command
  # substitution strips the trailing newline (order-dependent open); a rename
  # deletes its old path. All must read as NOT docs-only — otherwise a code PR
  # could pass check (a) with only a traceability keyword.
  expect_docs_only 'injected newline filename' $'added\tdocs/a.md\t\nadded\t\nscripts/evil.sh' false
  expect_docs_only 'bare newline filename' $'added\tdocs/a.md\t\nadded\t\n\t' false
  expect_docs_only 'tab inside filename' $'added\tdocs/a.md\t\nadded\tdocs\tb.md\t' false
  expect_docs_only 'unknown status token' $'weird\tdocs/a.md\t' false
  expect_docs_only 'empty filename LAST row' $'added\tdocs/a.md\t\nadded\t\t' false
  expect_docs_only 'empty filename first row' $'added\t\t\nadded\tdocs/a.md\t' false
  expect_docs_only 'renamed docs to docs' $'renamed\tdocs/b.md\tdocs/a.md' true
  expect_docs_only 'renamed code to docs' $'renamed\tdocs/x.md\tscripts/x.sh' false
  expect_docs_only 'renamed without previous' $'renamed\tdocs/x.md\t' false
  # Row-by-row validation cannot catch a forgery whose injected material is
  # itself well formed. Distinct-new-path equality against .changed_files does.
  expect_docs_only 'forged row while expected=1' $'added\tdocs/a.md\t\nadded\tdocs/plans/fake.md\t' false 1
  expect_docs_only 'count matches expected' $'added\tdocs/a.md\t' true 1
  expect_docs_only 'truncated list (expected=2, got 1)' $'added\tdocs/a.md\t' false 2
  # `.changed_files` counts distinct PATHS but pulls/files returns one entry per
  # DIFF ENTRY, so a delete+add on one path is two rows for one path. Comparing
  # rows would falsely block such a PR (a symlink converted to a regular file).
  expect_docs_only 'delete+add same docs path (2 rows, 1 path)' $'removed\tdocs/x.md\t\nadded\tdocs/x.md\t' true 1
  expect_docs_only 'delete+add same docs path, reversed order' $'added\tdocs/x.md\t\nremoved\tdocs/x.md\t' true 1
  expect_docs_only 'delete+add same docs path, expected=2 (honest mismatch)' $'removed\tdocs/x.md\t\nadded\tdocs/x.md\t' false 2
  # The old path must be judged for EVERY status, not just `renamed`: a
  # filename containing a newline splits one real file into two well-formed
  # rows, and the non-docs old path can land on a row labelled `added`.
  expect_docs_only 'split-row: non-docs old path on an added row' $'renamed\tdocs/x\tdocs/old\nadded\tdocs/y\tscripts/evil.sh' false
  expect_docs_only 'copied: docs new + code old' $'copied\tdocs/x.md\tscripts/x.sh' false
  # `unchanged` is in GitHub's documented diff-entry status enum; rejecting it
  # would wrongly block a legitimate docs-only PR.
  expect_docs_only 'unchanged status' $'unchanged\tdocs/a.md\t' true
  expect_docs_only 'at the 3000-file API cap' "$(i=0; while [[ $i -lt 3000 ]]; do printf 'added\tdocs/f%s.md\t\n' "$i"; i=$((i+1)); done)" false
  expect_docs_only 'just under the cap' "$(i=0; while [[ $i -lt 2999 ]]; do printf 'added\tdocs/f%s.md\t\n' "$i"; i=$((i+1)); done)" true
  # The cap counts DISTINCT paths, so a 3000-row list of 1500 delete+add pairs
  # is a complete, valid docs-only list and must NOT be denied the fallback.
  expect_docs_only '3000 rows / 1500 distinct docs paths' "$(i=0; while [[ $i -lt 1500 ]]; do printf 'removed\tdocs/f%s.md\t\nadded\tdocs/f%s.md\t\n' "$i" "$i"; i=$((i+1)); done)" true

  expect_resolve() {
    local desc="$1" body="$2" files="$3" expected="$4" got
    got="$(resolve_issue_ref "$body" "$files")"
    if [[ "$got" == "$expected" ]]; then
      printf '✅ resolve_issue_ref(%s) → %q\n' "$desc" "$got"
    else
      printf '❌ resolve_issue_ref(%s) → %q (expected %q)\n' "$desc" "$got" "$expected" >&2
      selffail=$((selffail + 1))
    fi
  }
  DOCS_ONLY_FILES=$'added\tdocs/plans/x.md\t'
  CODE_FILES=$'added\tscripts/z.sh\t'
  expect_resolve 'trace + docs-only' 'Refs #631' "$DOCS_ONLY_FILES" "$GH_REPO#631"
  expect_resolve 'trace + code' 'Refs #631' "$CODE_FILES" ''
  # The closing form must win even on a docs-only PR, and must work even when
  # the PR touches code (closure semantics are never weakened for code PRs).
  expect_resolve 'closing beats trace (docs-only)' 'Refs #631 then Closes #701' "$DOCS_ONLY_FILES" "$GH_REPO#701"
  expect_resolve 'closing + code' 'Refs #631 then Closes #701' "$CODE_FILES" "$GH_REPO#701"
  expect_resolve 'no ref at all' 'nothing here' "$CODE_FILES" ''
  # ── #720: closing-keyword parity with record-review.sh ────────────────────
  # CLOSING_KW must stay UNANCHORED (byte-identical to
  # record-review.sh::closing_issue_refs). These two vectors are what pin the
  # unanchored form — re-anchoring CLOSING_KW fails them here.
  expect_ref 'prefixes #42' "$GH_REPO#42"
  expect_ref 'bugfixes #42' "$GH_REPO#42"
  # The TRACE pattern IS anchored, so these must not resolve.
  expect_trace 'prefs #42' ''
  expect_trace 'preferences #42' ''

  if [[ "$selffail" -gt 0 ]]; then
    echo "❌ SELF-TEST FAILED ($selffail assertion(s))." >&2
    exit 2
  fi
  echo "✅ SELF-TEST PASS — parse_issue_ref handles bare #N, owner/repo#N, full URL, and pull-URL exclusion; parse_trace_ref handles the docs-only traceability form; pr_is_docs_only gates the fallback and fails closed; resolve_issue_ref prefers closure."
  exit 0
fi

# ── Live run ────────────────────────────────────────────────────────────────
PR_BODY="$(fetch_json "pulls/$PR_NUMBER" '.body // ""')"

# Files fetched as "status<TAB>filename<TAB>previous_filename" — check e needs
# the status to count only added/modified test files as evidence; checks d/e
# derive plain names; check (a)'s docs-only gate needs the old path to judge
# renames. Fetched BEFORE the issue resolution: check (a)'s docs-only fallback
# needs the file list to decide whether a non-closing keyword is acceptable.
FILES="$(fetch_json "pulls/$PR_NUMBER/files" '.[] | "\(.status)\t\(.filename)\t\(.previous_filename // "")"' 1)"
# Authoritative file count for this PR. files_rows demands the validated
# DISTINCT-new-path count EQUAL this, which is what makes a forged or
# truncated list unable to read as complete (and so unable to look
# docs-only). Distinct paths, not rows: .changed_files counts paths while
# pulls/files returns one entry per diff entry.
FILES_EXPECTED="$(fetch_json "pulls/$PR_NUMBER" '.changed_files // ""')"

# Resolve the linked issue (needed before the b–e fetches can run).
# resolve_issue_ref returns "owner/repo#N"; split so labels/comments are
# fetched from the issue's OWN repo — cross-repo refs would otherwise 404
# against the PR's repo or resolve the wrong repo's same-numbered issue.
LIVE_ISSUE_REF="$(resolve_issue_ref "$PR_BODY" "$FILES")"
LIVE_ISSUE="${LIVE_ISSUE_REF##*#}"
LIVE_ISSUE_REPO="${LIVE_ISSUE_REF%#*}"
LIVE_ISSUE_REPO="${LIVE_ISSUE_REPO:-$GH_REPO}"
LABELS=""
SCOPING_COMMENT=""
if [[ -n "$LIVE_ISSUE_REF" ]]; then
  echo "Resolving linked issue $LIVE_ISSUE_REF (labels/comments from repos/$LIVE_ISSUE_REPO/issues/$LIVE_ISSUE)..." >&2
  LABELS="$(fetch_json "issues/$LIVE_ISSUE/labels" '.[].name' 1 "$LIVE_ISSUE_REPO")"
  SCOPING_COMMENT="$(fetch_json "issues/$LIVE_ISSUE/comments" '.[].body' 1 "$LIVE_ISSUE_REPO")"
fi
COMMIT_MSGS="$(fetch_json "pulls/$PR_NUMBER/commits" '.[].commit.message' 1)"
# C3: bind check (f)'s recorded gate line to the PR's head. Fetched here (the
# single place network reads happen) so run_checks stays pure/offline.
PR_HEAD_SHA="$(fetch_json "pulls/$PR_NUMBER" '.head.sha // ""')"

run_checks || true
summarize
