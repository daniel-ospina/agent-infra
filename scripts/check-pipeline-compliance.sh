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

# parse_issue_ref <text> — print the first issue reference resolved by a
# closing keyword in <text>, as "owner/repo#N" ("" when none). The repo
# defaults to $GH_REPO for a bare "#N". Accepted forms, in priority order:
#   a. full URL  https://github.com/<owner>/<repo>/issues/<n>
#                (must NOT match .../pull/<n>)
#   b. owner/repo#<n>
#   c. bare #<n> → repo = $GH_REPO
# Each form greps the closing keyword directly followed by the reference (so
# e.g. "resolves SLACK_APPROVAL_FILE" is not mistaken for an issue ref).
parse_issue_ref() {
  local text="$1" m repo num kw
  kw='(fix(es|ed)?|close(s|d)?|resolve(s|d)?)'
  # a. full URL — /issues/<n> explicitly, never /pull/<n>.
  m="$(printf '%s\n' "$text" | grep -ioE "${kw}[[:space:]]*https://github.com/[^/[:space:],;)]+/[^/[:space:],;)]+/issues/[0-9]+" | head -1 || true)"
  if [[ -n "$m" ]]; then
    repo="$(printf '%s' "$m" | grep -oE 'https://github.com/[^/[:space:],;)]+/[^/[:space:],;)]+/issues/[0-9]+' | sed -E 's#https://github.com/([^/]+/[^/]+)/issues/[0-9]+.*#\1#' | head -1 || true)"
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
run_checks() {
  local issue_ref="" issue_number="" issue_repo="" issue_display="" plan_file="" wiring_found="no"
  local is_micro=false is_stdcomplex=false
  local tier="unspecified"
  local files_plain="" runtime_file="" test_evidence=""

  # Plain filenames (status stripped) from the files fetch — shared by the
  # plan-doc (d) and test-coverage (e) checks.
  files_plain="$(printf '%s\n' "$FILES" | awk -F '\t' 'NF >= 2 { print $2 }' || true)"

  echo "=== Pipeline Compliance Gate ==="
  echo "PR:   $GH_REPO#$PR_NUMBER"
  echo ""

  # a. LINKED ISSUE — closing keyword in the PR body. parse_issue_ref returns
  # "owner/repo#N" (repo = $GH_REPO for bare "#N"); split for display. The
  # live run additionally splits off the repo so labels/comments are fetched
  # from the issue's own repo.
  issue_ref="$(parse_issue_ref "$PR_BODY")"
  issue_number="${issue_ref##*#}"
  issue_repo="${issue_ref%#*}"
  issue_display="#$issue_number"
  if [[ -n "$issue_ref" && -n "$issue_repo" && "$issue_repo" != "$GH_REPO" ]]; then
    issue_display="$issue_repo#$issue_number"
  fi
  if [[ -n "$issue_ref" ]]; then
    pass a "linked issue $issue_display (closing keyword in PR body)"
  else
    fail a "no linked issue — PR body must reference the issue with a closing keyword (\"Fixes #N\" / \"Closes #N\" / \"Resolves #N\", or owner/repo#N / full issue URL for cross-repo)."
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
    if printf '%s\n%s\n' "$PR_BODY" "$COMMIT_MSGS" | grep -qiE 'code-review|reviewer|\[review\]|VGATE|review[[:space:]]+recorded|review-enforcer'; then
      pass c "code-review evidence in PR body/commits (review dispatch marker)"
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
      if [[ -n "$plan_file" ]]; then
        pass d "plan doc in PR ($plan_file)"
      elif [[ "$wiring_found" == "yes" ]]; then
        pass d "plan evidence: Wiring section (wiring-check table) in scoping comment"
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
    if [[ -z "$runtime_file" ]]; then
      echo "ℹ️  [e] Skipped: no runtime code changes (extensions/**/*.ts|js, bin/*.js) in this PR."
    else
      test_evidence="$(printf '%s\n' "$FILES" | awk -F '\t' '$1 == "added" || $1 == "modified" { print $2 }' | grep -E '\.test\.(ts|js)$' | head -1 || true)"
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
  echo "  a. LINKED ISSUE      gh api repos/$GH_REPO/pulls/$PR_NUMBER   → parse PR body for closing keywords (Fixes/Closes/Resolves #N, owner/repo#N, or full https://github.com/owner/repo/issues/N URL)"
  echo "                      labels + scoping comments are fetched from the issue's OWN repo when it differs from $GH_REPO (cross-repo)"
  echo "  b. SCOPING COMMENT   gh api repos/$GH_REPO/issues/<n>/comments → search for '<!-- issue-scoping:' marker"
  echo "  c. CODE-REVIEW EVID  gh api repos/$GH_REPO/pulls/$PR_NUMBER/commits + PR body → search review markers (code-review, reviewer, [review], VGATE, review recorded, review-enforcer)"
  echo "  d. PLAN DOC          gh api repos/$GH_REPO/pulls/$PR_NUMBER/files → docs/plans/*.md change, or 'Wiring' in scoping comment (complexity:standard/complex only)"
  echo "  e. TEST-COVERAGE EVID gh api repos/$GH_REPO/pulls/$PR_NUMBER/files → runtime code changes (extensions/**/*.ts excl. *.test.ts, extensions/**/*.js, bin/*.js) need test files in the diff or test-run markers in PR body/commits"
  echo ""
  echo "Exemptions: complexity:micro label skips b–e; no standard/complex label skips d; docs/skills/templates/config-only PRs (no runtime code) skip e."
  echo "Exit: 0 (compliant, simulated)."
  echo "For failure-path simulation: PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1"
  echo "For parser-only self-test (no gh calls): PIPELINE_COMPLIANCE_SELF_TEST=1"
  exit 0
fi

# ── Failure simulation (offline test of failure output paths) ───────────────
if [[ "$FAIL_ALL" == "1" ]]; then
  # Pass 1: no linked issue → a fails, b–e skipped.
  echo "== SIMULATION: all-failures pass 1 of 3 (no linked issue) =="
  PR_BODY=""; LABELS=""; SCOPING_COMMENT=""; COMMIT_MSGS=""; FILES=""
  FAILURES=0
  run_checks || true
  summarize || true

  # Pass 2: standard/complex issue, all evidence missing → a passes (keyword
  # parser exercised), b/c/d/e fail. FILES includes a runtime-code change so
  # check e runs (and fails) rather than being skipped.
  echo ""
  echo "== SIMULATION: all-failures pass 2 of 3 (standard/complex issue, no evidence) =="
  PR_BODY="Fixes #1"; LABELS="complexity:standard"; SCOPING_COMMENT=""; COMMIT_MSGS=""
  FILES=$'added\textensions/example/sample.ts'
  FAILURES=0
  run_checks || true
  summarize || true

  # Pass 3: cross-repo issue reference. parse_issue_ref must resolve the
  # issue's OWN repo (daniel-ospina/swarm), not GH_REPO — the gate then
  # fetches labels/comments from repos/daniel-ospina/swarm/issues/2492.
  # Assert the parse directly (pure shell, no gh) and exercise run_checks
  # with the cross-repo body (a passes and displays the full owner/repo#N ref).
  echo ""
  echo "== SIMULATION: pass 3 of 3 (cross-repo issue reference) =="
  ref="$(parse_issue_ref 'Fixes daniel-ospina/swarm#2492')"
  [[ "$ref" == "daniel-ospina/swarm#2492" ]] || { echo "❌ SELF-TEST FAIL: parse_issue_ref('Fixes daniel-ospina/swarm#2492') = '$ref', expected 'daniel-ospina/swarm#2492'." >&2; exit 2; }
  ref="$(parse_issue_ref 'Closes https://github.com/daniel-ospina/swarm/issues/2492')"
  [[ "$ref" == "daniel-ospina/swarm#2492" ]] || { echo "❌ SELF-TEST FAIL: full-URL parse = '$ref', expected 'daniel-ospina/swarm#2492'." >&2; exit 2; }
  ref="$(parse_issue_ref 'Resolves https://github.com/daniel-ospina/agent-infra/pull/171')"
  [[ -z "$ref" ]] || { echo "❌ SELF-TEST FAIL: pull-request URL must NOT parse as an issue, got '$ref'." >&2; exit 2; }
  ref="$(parse_issue_ref 'Fixes #7')"
  [[ "$ref" == "$GH_REPO#7" ]] || { echo "❌ SELF-TEST FAIL: bare #N parse = '$ref', expected '$GH_REPO#7'." >&2; exit 2; }
  # Regression: a non-issue token after a closing keyword must not shadow a
  # real ref later in the text (PR #171's body: "resolves SLACK_APPROVAL_FILE … Closes #2492").
  ref="$(parse_issue_ref 'resolves SLACK_APPROVAL_FILE first, then Closes #2492')"
  [[ "$ref" == "$GH_REPO#2492" ]] || { echo "❌ SELF-TEST FAIL: keyword + non-issue token shadowing = '$ref', expected '$GH_REPO#2492'." >&2; exit 2; }
  PR_BODY="Fixes daniel-ospina/swarm#2492"; LABELS="complexity:standard"; SCOPING_COMMENT=""; COMMIT_MSGS=""
  FILES=$'added\textensions/example/sample.ts'
  FAILURES=0
  run_checks || true
  summarize || true
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
  expect_ref 'Resolves #7' "$GH_REPO#7"
  expect_ref 'FIXES #9' "$GH_REPO#9"
  expect_ref 'Fixes https://github.com/daniel-ospina/agent-infra/pull/171' ''
  expect_ref 'Fixes #173, Closes #174' "$GH_REPO#173"
  expect_ref 'This fixes #42 in passing' "$GH_REPO#42"
  expect_ref 'resolves SLACK_APPROVAL_FILE first, then Closes #2492' "$GH_REPO#2492"
  expect_ref 'Closes #173.' "$GH_REPO#173"
  expect_ref 'No issue referenced here' ''
  if [[ "$selffail" -gt 0 ]]; then
    echo "❌ SELF-TEST FAILED ($selffail assertion(s))." >&2
    exit 2
  fi
  echo "✅ SELF-TEST PASS — parse_issue_ref handles bare #N, owner/repo#N, full URL, and pull-URL exclusion."
  exit 0
fi

# ── Live run ────────────────────────────────────────────────────────────────
PR_BODY="$(fetch_json "pulls/$PR_NUMBER" '.body // ""')"

# Resolve the linked issue (needed before the b–e fetches can run).
# parse_issue_ref returns "owner/repo#N"; split so labels/comments are
# fetched from the issue's OWN repo — cross-repo refs would otherwise 404
# against the PR's repo or resolve the wrong repo's same-numbered issue.
LIVE_ISSUE_REF="$(parse_issue_ref "$PR_BODY")"
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
# Files fetched as "status<TAB>filename" — check e needs the status to count
# only added/modified test files as evidence; checks d/e derive plain names.
FILES="$(fetch_json "pulls/$PR_NUMBER/files" '.[] | "\(.status)\t\(.filename)"' 1)"

run_checks || true
summarize
