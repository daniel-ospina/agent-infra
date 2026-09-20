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
#                          for cross-repo issues) that BEGINS A LINE, optionally
#                          after a Markdown line-leading prefix — bullet,
#                          ordered-list marker, blockquote, ATX heading or
#                          task-list checkbox (compound included) — and/or an
#                          emphasis/bold/backtick marker. A mid-sentence
#                          mention is not a reference (#1012).
#                          For cross-repo refs the
#                          labels (tier) and scoping comments (checks b–e) are
#                          fetched from the issue's OWN repo, not the PR's.
#                          A PR whose diff is ENTIRELY an artifact under docs/,
#                          instruction-layer Markdown (skills/**/*.md,
#                          AGENTS.md), or .github/CODEOWNERS may
#                          instead use a NON-closing traceability keyword
#                          (Refs / Part of / Advances / Tracks / Relates to).
#                          Rationale: a planning/instruction-artifact PR
#                          implements no runtime work, so demanding a closing
#                          keyword would force a FALSE close of the linked
#                          issue — often an open parent whose children carry
#                          the work. The closing form always wins when both are
#                          present, and the fallback is unreachable for any PR
#                          that touches a code path (pr_is_artifact_only).
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
#   #792 pre-PR mode (issue-side artifacts only — b + d-via-Wiring):
#   bash scripts/check-pipeline-compliance.sh --issue-only <N|owner/repo#N>
#
# Env:
#   GH_REPO                       owner/repo (default: auto-detect from git remote)
#   PR_NUMBER                     PR number (or positional arg)
#   PIPELINE_COMPLIANCE_ISSUE_ONLY  1 = #792 issue-only (pre-PR) mode
#   PIPELINE_COMPLIANCE_ISSUE       issue for issue-only mode: N or owner/repo#N
#   PIPELINE_COMPLIANCE_SKIP      1 = emergency override: skip gate, loud warning
#   PIPELINE_COMPLIANCE_DRY_RUN   1 = print what WOULD be checked, no gh calls
#   PIPELINE_COMPLIANCE_FAIL_ALL  1 = with DRY_RUN: simulate failures to exercise
#                                 failure output paths offline (unit-testable)
#   PIPELINE_COMPLIANCE_SELF_TEST 1 = run parse_issue_ref self-test, no gh calls
set -euo pipefail

# ── Inputs ──────────────────────────────────────────────────────────────────
PR_NUMBER="${1:-${PR_NUMBER:-}}"
# #792 — issue-only (pre-PR) mode. Evaluates the target issue's artifacts
# (b scoping comment; d via the file-independent Wiring branch) and skips the
# PR-diff-dependent checks (a, c, e), which have nothing to read before a PR
# exists. It exists so the commit-workflow preflight can detect a missing
# artifact in seconds instead of after a completed review loop + PR, where the
# retro artifact invalidates the reviewed SHA and the gate cost is paid twice.
# It NEVER changes a full-PR verdict: ISSUE_ONLY=0 is the only path a PR takes.
ISSUE_ONLY="${PIPELINE_COMPLIANCE_ISSUE_ONLY:-0}"
# The env seam is read OUTSIDE the argv branch (review catch): assigning it
# inside made `PIPELINE_COMPLIANCE_ISSUE_ONLY=1 PIPELINE_COMPLIANCE_ISSUE=N \
# bash …` — the exact form this script's own usage() documents — exit 2 with
# "needs an issue", i.e. the documented env form could never work.
ENV_ISSUE_TARGET="${PIPELINE_COMPLIANCE_ISSUE:-}"
ISSUE_TARGET="$ENV_ISSUE_TARGET"
ISSUE_REF=""
ISSUE_ARGV_ERR=""
if [[ "${1:-}" == "--issue-only" ]]; then
  ISSUE_ONLY=1
  # The argv flag AND the env seam both naming a target is two targets, not one
  # silently overriding the other (review catch: `PIPELINE_COMPLIANCE_ISSUE=42
  # … --issue-only 999` graded 999 with 42 dropped).
  if [[ -n "$ENV_ISSUE_TARGET" ]]; then
    ISSUE_ARGV_ERR="two issue targets: --issue-only was passed on the command line and PIPELINE_COMPLIANCE_ISSUE is also set ('$ENV_ISSUE_TARGET') — pass exactly one target"
  fi
  ISSUE_TARGET="${2:-$ISSUE_TARGET}"
  # Exactly one target. A surplus argument is a usage error, never silently
  # ignored (review catch).
  if [[ $# -gt 2 ]]; then
    ISSUE_ARGV_ERR="--issue-only takes exactly one issue target, got a surplus argument: '${3}'"
  fi
  PR_NUMBER=""
elif [[ "$ISSUE_ONLY" == "1" && $# -gt 0 && -n "$ISSUE_TARGET" ]]; then
  # The ENV seam supplied the target and a positional was ALSO given: the
  # positional used to be dropped silently (`ISSUE_ONLY=1 ISSUE=42 script 792`
  # graded 42 while the caller meant 792). That is the same ambiguity the argv
  # surplus rule rejects, so it is a usage error here too (review catch).
  ISSUE_ARGV_ERR="PIPELINE_COMPLIANCE_ISSUE is set ('$ISSUE_TARGET') and a positional argument was also given ('${1}') — pass exactly one target"
elif [[ $# -gt 1 ]]; then
  # `--issue-only` anywhere but argv[1] is a misordered invocation, NOT a PR
  # number plus a stray flag (review catch): `<N> --issue-only` used to fall
  # through to the FULL-PR gate, grade an unrelated PR, and return a PASS/BLOCK
  # the caller believed was an issue-side verdict. A wrong-gate verdict is
  # worse than a usage error.
  for _a in "${@:2}"; do
    if [[ "$_a" == "--issue-only" ]]; then
      ISSUE_ARGV_ERR="--issue-only must be the first argument (bash $0 --issue-only <N|owner/repo#N>)"
    fi
  done
fi
GH_REPO="${GH_REPO:-}"
DRY_RUN="${PIPELINE_COMPLIANCE_DRY_RUN:-0}"
FAIL_ALL="${PIPELINE_COMPLIANCE_FAIL_ALL:-0}"
# Authoritative PR file count (pulls .changed_files). Set by the live fetch;
# files_rows demands the validated DISTINCT-new-path count equal it, so a
# forged or truncated diff list cannot read as complete. Empty (or 0) = not
# enforced — offline simulations construct the list in-process.
FILES_EXPECTED=""

usage() {
  cat >&2 <<'EOF'
Usage:
  bash scripts/check-pipeline-compliance.sh <PR_NUMBER>
  PR_NUMBER=123 GH_REPO=owner/repo bash scripts/check-pipeline-compliance.sh

  #792 pre-PR mode — issue-side artifacts only (b + d-via-Wiring):
  bash scripts/check-pipeline-compliance.sh --issue-only <N|owner/repo#N>
  PIPELINE_COMPLIANCE_ISSUE_ONLY=1 PIPELINE_COMPLIANCE_ISSUE=<N|owner/repo#N> \
    bash scripts/check-pipeline-compliance.sh

Env:
  GH_REPO                       owner/repo (default: auto-detect from git remote)
  PIPELINE_COMPLIANCE_ISSUE_ONLY  1 = issue-only (pre-PR) mode
  PIPELINE_COMPLIANCE_ISSUE       issue for issue-only mode: N or owner/repo#N
  PIPELINE_COMPLIANCE_SKIP=1    emergency override (loud warning)
  PIPELINE_COMPLIANCE_DRY_RUN=1 print what WOULD be checked (no gh calls)
  PIPELINE_COMPLIANCE_FAIL_ALL=1 with DRY_RUN: simulate all failures
  PIPELINE_COMPLIANCE_SELF_TEST=1 parser-only self-test (no gh calls)

Check (a) scope:
  A closing keyword ("Fixes #N" / "Closes #N" / "Resolves #N", or owner/repo#N
  / a full issue URL) must BEGIN A LINE, optionally preceded by a Markdown
  line-leading prefix — a bullet, ordered-list marker, blockquote, ATX heading
  or task-list checkbox (compound/nested prefixes included) — and/or an
  emphasis/bold/backtick marker. A mid-sentence mention does NOT
  count, because it can auto-close an issue on merge (#1012).
  A diff that is ENTIRELY an artifact — under docs/, instruction-layer Markdown
  (skills/**/*.md, AGENTS.md), or .github/CODEOWNERS — may instead use a
  NON-closing traceability keyword (Refs / Part of / Advances / Tracks /
  Relates to #N); closure is not implied. Any .ts/.js/.mjs/script/workflow path
  makes that fallback unreachable (#786).
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
if [[ -n "$ISSUE_ARGV_ERR" ]]; then
  echo "❌ $ISSUE_ARGV_ERR" >&2
  usage
  exit 2
fi
if [[ ! "$ISSUE_ONLY" =~ ^[01]$ ]]; then
  echo "❌ PIPELINE_COMPLIANCE_ISSUE_ONLY must be 0 or 1, got: '$ISSUE_ONLY'." >&2
  exit 2
fi
if [[ "$ISSUE_ONLY" == "1" ]]; then
  # #792 pre-PR mode: the target is an ISSUE, not a PR. A bare number resolves
  # against $GH_REPO below; owner/repo#N is explicit (cross-repo supported, the
  # same way check (a) resolves a cross-repo reference).
  if [[ -z "$ISSUE_TARGET" ]]; then
    echo "❌ --issue-only needs an issue: bash scripts/check-pipeline-compliance.sh --issue-only <N|owner/repo#N>" >&2
    usage
    exit 2
  fi
  if [[ ! "$ISSUE_TARGET" =~ ^([0-9]+|[^/[:space:]]+/[^/[:space:]]+#[0-9]+)$ ]]; then
    echo "❌ --issue-only target must be an issue number or owner/repo#N, got: '$ISSUE_TARGET'." >&2
    exit 2
  fi
elif [[ -z "$PR_NUMBER" && "${PIPELINE_COMPLIANCE_SELF_TEST:-0}" != "1" ]]; then
  echo "❌ No PR number given." >&2
  usage
  exit 2
elif [[ ! "$PR_NUMBER" =~ ^[0-9]+$ && "${PIPELINE_COMPLIANCE_SELF_TEST:-0}" != "1" ]]; then
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
# Which issue-side checks actually RAN, so the --issue-only PASS line reports
# only artifacts that were read (the micro exemption and an unlabeled tier skip
# parts of b/d — review catch: the PASS text used to claim both unconditionally).
B_CHECKED="no"
D_CHECKED="no"
pass() { printf '✅ [%s] %s\n' "$1" "$2"; }
fail() { printf '❌ [%s] %s\n' "$1" "$2"; FAILURES=$((FAILURES + 1)); }
# Reference CONTEXT (#1012) — where a closing OR traceability keyword must sit
# to count as a reference rather than a mention. The keyword begins a line,
# optionally after ONE OR MORE Markdown prefixes GitHub renders as a
# line-leading reference marker — a bullet ("- " / "* " / "+ "), an
# ordered-list marker ("1. " / "1) "), a blockquote ("> " / ">> "), an ATX
# heading ("# " … "###### "), a task-list checkbox ("[ ] " / "[x ]") — and/or
# emphasis / bold / backtick marks. The prefix and checkbox groups are
# REPEATABLE, so COMPOUND prefixes count too (`> - Closes #42`,
# `> > Closes #42`, `>> Closes #42`): nesting is still a reference context that
# auto-closes on GitHub, while a single-consumption group false-BLOCKED check
# (a) on exactly those shapes (#1012 r3). An UNANCHORED match read a sentence
# that merely DISCUSSED a closing keyword as a reference: PR #968's status note
# "…a closing keyword would falsely close #949…" satisfied check (a) AND would
# have auto-closed #949 on merge. Position is the contract, exactly as #991
# made check (b) positional.
# The CROSS-SCRIPT CONTRACT is the keyword CLASS, not the position rule: REFCTX
# and CLOSING_KW are byte-identical to record-review.sh's copies (pinned
# mechanically by record-review.test.sh §8.13), while record-review's #513 tier
# guard ALSO scans with a WORD-BOUNDARY-ANCHORED CLOSING_KW (`\b` + the class,
# NO REFCTX) — GitHub auto-closes a mid-sentence ref, so the tier guard must
# bind it even though check (a) ignores it, and `\b` keeps the class from
# matching INSIDE ordinary English words ("prefix", "discloses", "unresolved").
REFCTX='^[[:space:]]*(([-*+]|[0-9]+[.)])[[:space:]]+|#{1,6}[[:space:]]+|>[[:space:]]*)*(\[[ xX]\][[:space:]]+)*[*_`]{0,3}[[:space:]]*'

# Closing-keyword class (check a's default) and the NON-closing traceability
# class (the artifact-only fallback). \b anchors the TRACE keywords so a
# substring cannot masquerade as one ("prefs #42" must not read as
# "refs #42"). CLOSING_KW stays byte-identical to
# record-review.sh::closing_issue_refs (a documented cross-script contract);
# the positional REFCTX prefix is applied by BOTH scripts by default, so the
# POSITIONAL composed pattern is identical. The tier guard's GitHub-parity scan
# is the one place the composition differs: it composes `\b` + CLOSING_KW with
# NO REFCTX (see the REFCTX comment above) — the CLASS stays byte-identical, the
# position/boundary wrapper is chosen per scan. Both suites pin the COMPOSED
# form, and record-review.test.sh §8.13 pins the two constant lines
# byte-for-byte across the scripts (nothing asserted that equality before).
CLOSING_KW='(fix(es|ed)?|close(s|d)?|resolve(s|d)?)'
TRACE_KW='\b(ref(s|erences?)?|part[[:space:]]+of|advance(s|d)?|track(s|ed)?|relates?[[:space:]]+to)'

# Evidence patterns for checks (c) and (e) and the #513 clean-micro binding —
# the single source of truth, shared by the live checks and the SELF_TEST
# fixtures (so the regression test exercises the PRODUCTION path, not a copy).
REVIEW_EVIDENCE_RE='code-review|reviewer|\[review\]|VGATE|review[[:space:]]+recorded|review-enforcer'
TEST_EVIDENCE_RE='tests[[:space:]]+green|[0-9]+[[:space:]]+passed|[0-9]+/[0-9]+|VGATE[[:space:]]+PASS|test[[:space:]]+suite|pytest|npm[[:space:]]+test|vitest'
CLEAN_MICRO_MARKER_RE='verdict=clean-micro @ [0-9a-f]{40}'

# ── #836: never pipe a multi-KB string into `grep -q` ────────────────────────
# Under `set -euo pipefail`, `printf … | grep -q …` is a RACE on any input well
# above PIPE_BUF: `grep -q` exits at the FIRST match while `printf` is still
# writing, so `printf` takes SIGPIPE (exit 141) and pipefail makes the WHOLE
# pipeline non-zero. The `if`/`elif` then takes the else branch and reports
# PRESENT evidence as missing. Measured on PR #823: 3 failures in 4 runs, with
# the failure moving between checks (c) and (e) while the evidence text was
# unchanged (9 body / 6 commit matches for (c); 16 / 33 for (e)) and a re-run of
# the identical job passing. Reproduced locally at 66 KB: 20/25 runs of the old
# idiom false-negated, 0/25 with a here-string; at 256 KB and 1 MB the old idiom
# failed 30/30. The gate is a REQUIRED status check, so a false block can only be
# merged around with --admin/--auto — both gate bypasses.
#
# A here-string has NO reader process to close the write end: `grep -q` reads to
# EOF, so no SIGPIPE can reach the writer. These matchers are the ONLY call
# sites for the two evidence patterns — the SELF_TEST #836 fixtures call them
# directly, which is what makes the regression test a pin on the real code.
#
# The direction of the bug differed per site: pr_is_artifact_only's
# `! printf … | grep -qvE` and the #513 clean-micro binding were FAIL-OPEN (a
# raced pipeline read as "artifact-only" / "marker absent"), while checks (b), (c),
# (d) and (e) were fail-closed false BLOCKS.
#
# WHO CONVERTED WHAT: #716 (`0542c6d`, follow-ups `4230ffc`, `25a51e7`) already
# moved all eight sites to here-strings on `main`, so THIS change is the pin,
# not the conversion — it hoists the patterns above so the regression vectors
# exercise the production matchers, and adds the large-input controls. Every
# RED measurement quoted in this file (20/25 at 66 KB, 30/30 at 256 KB and
# 1 MB) is against the PRE-#716 idiom, not against this PR's diff.
has_review_evidence() { grep -qiE "$REVIEW_EVIDENCE_RE" <<<"$1"; }
has_test_evidence() { grep -qiE "$TEST_EVIDENCE_RE" <<<"$1"; }
has_clean_micro_marker() { grep -qE "$CLEAN_MICRO_MARKER_RE" <<<"$1"; }

# resolve_issue_only_ref <target> — map an --issue-only target to owner/repo#N:
# a bare number resolves against $GH_REPO, an explicit owner/repo#N passes
# through unchanged (cross-repo supported, the same way check (a) resolves a
# cross-repo reference). Pure — the SELF_TEST pins it without any gh call.
resolve_issue_only_ref() {
  case "$1" in
    */*'#'*) printf '%s' "$1" ;;
    *)       printf '%s#%s' "$GH_REPO" "$1" ;;
  esac
}

# parse_issue_ref <text> [<kw-pattern>] — print the first issue reference
# resolved by a closing keyword in <text>, as "owner/repo#N" ("" when none).
# The repo defaults to $GH_REPO for a bare "#N". Accepted forms, in priority order:
#   a. full URL  https://github.com/<owner>/<repo>/issues/<n>
#                (must NOT match .../pull/<n>)
#   b. owner/repo#<n>
#   c. bare #<n> → repo = $GH_REPO
# Each form greps the keyword directly followed by the reference (so e.g.
# "resolves SLACK_APPROVAL_FILE" is not mistaken for an issue ref), and the
# keyword must occupy a REFERENCE CONTEXT (REFCTX): it begins a line, optionally
# after a Markdown line-leading prefix (bullet / ordered marker / blockquote /
# ATX heading / task-list checkbox) or emphasis marker. A mid-sentence mention
# is NOT a reference (#1012) — that distinction is what keeps a sentence about a
# closing keyword from satisfying check (a) and auto-closing an issue on merge.
parse_issue_ref() {
  local text="$1" kwpat="${2:-$CLOSING_KW}" m repo num kw
  # Positional for BOTH classes: parse_trace_ref delegates here, so a
  # mid-sentence mention cannot unlock the artifact-only fallback either.
  kw="${REFCTX}${kwpat}"
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
# for an ARTIFACT-ONLY PR — see resolve_issue_ref / pr_is_artifact_only.
parse_trace_ref() { parse_issue_ref "$1" "$TRACE_KW"; }

# ── #1274 — the closing-word HAZARD scan ────────────────────────────────────
# GitHub decides whether to close an issue by matching WORDS, not by reading
# the sentence those words sit in. Two failures follow, and both happened for
# real on PR #1271:
#
#   H1  A closing word next to an issue reference closes that issue even when
#       the sentence says the opposite. The PR body carried the heading
#       "## ⚠️ This PR does NOT close #1178" — that text contains `close #1178`,
#       and GitHub closed #1178, whose units 4–5 were unbuilt. The word "NOT"
#       is invisible to the parser. A NEGATION IS AN INSTRUCTION.
#   H2  GitHub SKIPS inline code, so a closing keyword wrapped in backticks
#       closes nothing. The same body's INTENDED keyword was written as
#       `` `Closes #1254` ``: check (a) PASSED it (REFCTX tolerates a backtick
#       prefix, pinned by this file's own self-test) while GitHub ignored it and
#       #1254 was closed by hand instead.
#
# So check (a)'s question is not "is there a reference?" but "is the SET of
# issues this body will close exactly the set the author means to close?". The
# two functions below compute the difference; scan_close_word_hazards renders
# it as the gate's failure text. Position is deliberately irrelevant to H1 —
# GitHub acts on the words wherever they sit, which is also why the mid-sentence
# rule in check (a) cannot see this class: it treats a mid-sentence mention as
# NOT a reference, and it is one.
#
# SCOPE, stated rather than implied: this scans the PR BODY only. GitHub also
# acts on closing keywords in COMMIT MESSAGES, which this gate does not read —
# a known boundary, so do not read a PASS here as "no accidental closure".
#
# A second boundary, and it is the CONSERVATIVE direction on purpose: a FENCE,
# an HTML comment (`<!-- … -->`) and raw `<code>` HTML are all scanned as LIVE.
# For fenced code I could not establish whether GitHub skips it, and the earlier
# attempt to MODEL it produced four fail-opens in three review rounds (see the
# comment above all_close_refs); for HTML comments I could not establish it
# either. So this does NOT guess: a false block cleared by a one-word edit is the
# safe error, and refusing is the direction this gate exists for. A fenced body
# that quotes the keyword form is therefore refused — use inline code, which is
# inert, or drop the number from the sentence.
#
# The keyword class is word-boundary-anchored (`\b`): CLOSING_KW's class is a
# SUFFIX of ordinary English words ("prefix", "discloses", "unresolved"), so an
# unanchored scan invents hazards out of prose that closes nothing — the same
# false-refusal trap record-review.sh's tier guard documents.

# A FENCE IS NOT MODELLED — and that is deliberate. An earlier revision stripped
# fenced blocks so a body that QUOTED the keyword form would not be refused. That
# cost four defects in three review rounds, every one a FAIL-OPEN in the
# direction this gate exists to catch, each in a different input dimension of the
# same question "is this line a fence?": opener indentation (a 4-column opener is
# an indented code block, not a fence), an info string containing a backtick
# (CommonMark forbids it, so the line is a paragraph), and a fence-looking line
# inside an HTML comment (never a fence). A line-toggle that must be right about
# that question in every dimension is a net loss: getting it wrong HIDES a live
# closure, while not having it at all merely refuses a body that quotes a keyword
# inside a fence — visible, and cleared by using inline code or dropping the
# number.
#
# So the model is one rule: INLINE CODE IS INERT; EVERYTHING ELSE IS LIVE. That is
# the conservative direction, it needs no fence parser, and the inline-code half
# is the half GitHub's behaviour actually verifies (a backticked intended keyword
# demonstrably did not close its issue on PR #1271).
# all_close_refs <text> — every issue number <text> names with a closing
# keyword, one per line, ascending, deduped. This is the set of issues the body
# WILL close on merge. The cross-repo owner/repo prefix is dropped, so the
# returned value is the issue NUMBER; a cross-repo reference sharing a number
# with the target is therefore indistinguishable from it (conservative: the
# gate's message names the number either way).
all_close_refs() {
  printf '%s\n' "$1" \
    | grep -ioE "\\b${CLOSING_KW}[[:space:]]*:?[[:space:]]*(#[0-9]+|[^/[:space:],;)]+/[^/[:space:],;)]+#[0-9]+|https://github.com/[^/[:space:],;)]+/[^/[:space:],;)]+/issues/[0-9]+)" \
    | grep -oE '(#[0-9]+$|/[0-9]+$)' | grep -oE '[0-9]+' | sort -n -u
}

# code_span_close_refs <text> — the issue numbers whose closing keyword sits
# INSIDE inline code (backticks). GitHub skips code spans, so these are inert:
# they close nothing. Separated from all_close_refs rather than folded in,
# because an inert mention of a DIFFERENT issue is harmless noise while an inert
# mention of the INTENDED issue is the H2 failure.
code_span_close_refs() {
  printf '%s\n' "$1" \
    | grep -ioE '`[^`]*'"${CLOSING_KW}"'[^`]*(#[0-9]+|/[0-9]+)[^`]*`' \
    | grep -oE '(#[0-9]+|/[0-9]+)' | grep -oE '[0-9]+' | sort -n -u
}

# scan_close_word_hazards <text> <intended-number> — the gate's hazard text, or
# empty when clean. Disjointness is the whole point:
#   H1 = will-close MINUS inert MINUS intended  → an unintended closure
#   H2 = intended INTERSECT inert               → the intended closure disarmed
# An inert mention of some OTHER issue is neither (it closes nothing and was not
# intended), so it is not reported.
scan_close_word_hazards() {
  local text="$1" intended="$2" out="" n inert=" "
  for n in $(code_span_close_refs "$text"); do inert="$inert$n "; done
  for n in $(all_close_refs "$text"); do
    [[ "$n" == "$intended" ]] && continue
    case "$inert" in *" $n "*) continue ;; esac
    out+="      ⚠️  H1 unintended close: the body names #$n with a closing keyword, so GitHub will CLOSE #$n on merge. Its parser reads the words and not the sentence — a negation is not understood, so \"this does NOT close #$n\" IS that instruction."$'\n'
  done
  for n in $(code_span_close_refs "$text"); do
    [[ "$n" == "$intended" ]] || continue
    out+="      ⚠️  H2 disarmed close: the closing keyword for #$n is inside inline code (backticks). GitHub SKIPS code spans, so this closes NOTHING — the link the body intends will not be created and #$n stays open."$'\n'
  done
  printf '%s' "$out"
}

# has_scoping_marker <scoping-comment-text> — true when the text carries the
# `<!-- issue-scoping:` marker as a REAL scoping artifact rather than as a
# substring of prose.
#
# WHY THIS IS NOT A BARE SUBSTRING MATCH (#991). Check (b) is the ONLY
# enforcement that the scoping artifact exists for a non-micro issue, and the
# old form — `grep -qF '<!-- issue-scoping:'` — was satisfied by any comment
# that merely MENTIONED the marker, including one written to assert that no
# scoping comment exists. That is not an adversarial edge case: it happened by
# accident on #786, in a bug report explaining that a DIFFERENT issue lacked
# the artifact. Check (c) received exactly this precision fix under #513
# ("never bare prose mentioning the marker text"); (b) did not, so the two
# siblings drifted — the class tracked by the duplication audit on #917.
#
# EACH COMMENT IS EXAMINED SEPARATELY. The caller's jq appends a record
# separator (0x1e) per comment, so this scans EVERY comment and requires the
# marker to be the first line of ONE of them — which is what the check's own
# message has always claimed ("one of its comments"). (The message used to say
# "must START with the marker"; that phrasing predates the footer tolerance and
# is no longer accurate, so the code and the message now read the same way:
# first content line, or last one set off by a blank line.)
# Testing only the concatenation's first line silently checked the THREAD's
# oldest comment instead, and that was a regression: issue #883's genuine
# artifact is comment 3, posted after two discussion comments, so it failed
# under this revision where all five previous generations had passed it. The
# retrospective case — artifact posted after discussion — is exactly when that
# happens, so it had to be fixed here rather than filed.
#
# The marker must be at COLUMN 0 of that comment's first CONTENT line — where
# "content" means the first line that is neither blank nor an ATX heading. Two
# reasons, both measured rather than assumed:
#
#   * Leading whitespace is NOT stripped. GFM renders a first line indented >= 4
#     columns (4 spaces, or a tab) as an INDENTED CODE BLOCK, which DISPLAYS the
#     marker text — a mention, not a hidden artifact. An earlier revision of this
#     comment stripped it, re-admitting exactly the false-pass class this check
#     exists to remove (all four parser generations had rejected it).
#   * Leading ATX HEADINGS are skipped, because the producer emits BOTH shapes:
#     `<!-- issue-scoping: … -->` on line 1 (#949, #991, #883's comment 3), and
#     `## Scope — …` / `## Scoping — …` on line 1 with the marker on line 3
#     (#729, #843, #857, #858 — all genuine, all rejected by a strict first-line
#     rule). A prose PREFACE is still rejected: prose is neither blank nor a
#     heading, so it must itself be the marker, and it is not. This keeps the
#     false-pass class closed — a fenced or blockquoted example opens with ```
#     or `>`, neither of which is a heading — while accepting both documented
#     artifact shapes.
#
# Cost, stated plainly: a marker indented on its first line still FAILS, and a
# prose preface still FAILS. Both are deliberate and loud — the failure message
# names the required position.
has_scoping_marker() {
  # RS = 0x1e, injected by the caller's jq. See the sanitization note at each
  # fetch site: the separator is in-band, so the data is stripped of it first.
  #
  # POSITION IS THE CONTRACT. An artifact carries the marker either as the
  # comment's FIRST line with content, or as its LAST one when set off by a
  # blank line. Both branches ask WHERE the marker sits — never what Markdown
  # makes of it — so there is no fence, indentation or container grammar left to
  # get wrong. Measured over this repo's 235 marker-bearing comments: 223 first,
  # 2 last (the two #783 artifacts), 10 neither — and all 10 are prose, tables
  # or fenced examples, i.e. mentions.
  awk -v RS='\036' '
    {
      n = split($0, lines, "\n")
      # Branch 1 — the first line with content, skipping blanks and any leading
      # ATX headings (the producer emits both a bare-marker and a heading-first
      # shape: four real artifacts open with an ATX heading — #729 uses
      # "## Scoping — #729", the other three "## Scope —").
      j = 0
      while (j < n && (lines[j+1] ~ /^[[:space:]]*$/ || lines[j+1] ~ /^#{1,6}[[:space:]]/)) j++
      if (j < n && lines[j+1] ~ /^<!-- issue-scoping:/) found = 1
      # Branch 2 — the last line with content, and only when a blank line sets
      # it off as a footer block. Drop the blank-line condition and a crowded
      # "preamble\n<marker>" passes, which is the mention shape.
      k = n
      while (k >= 1 && lines[k] ~ /^[[:space:]]*$/) k--
      if (k >= 2 && lines[k] ~ /^<!-- issue-scoping:/ && lines[k-1] ~ /^[[:space:]]*$/) found = 1
    }
    END { exit(found ? 0 : 1) }
  ' <<<"$1"
}

# files_rows <files> — validate the UNTRUSTED diff list from pulls/files and
# print its well-formed rows. Returns 1 without output if ANY row is
# malformed, because a single bad row makes the whole list untrustworthy.
#
# Every consumer of the file list MUST go through this (or pr_is_artifact_only,
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
      # be accepted, or a legitimate artifact-only PR is wrongly BLOCKED.
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

# pr_is_artifact_only <files> — true when the PR's diff is ENTIRELY an artifact:
# under docs/, instruction-layer Markdown (skills/**/*.md, AGENTS.md), or the
# review-routing config .github/CODEOWNERS.
# `files` is the "<status><TAB><filename><TAB><old>" list from the pulls/files
# fetch. Fails CLOSED on anything it cannot prove, because this predicate is
# what unlocks check (a)'s non-closing keyword — a false `true` would let a
# code PR dodge closure.
#
# THE CLASS IS A POSITIVE ALLOWLIST (#786), not a negative "no executable
# extension" rule: docs/ (any file — the #720 carve-out), instruction-layer
# Markdown that ships governance/skill prose but no runtime work,
# .github/CODEOWNERS (review-routing config with no executable logic — the
# #786 headline case, PR #674), and nothing else. A negative rule was rejected
# because a new or unlisted file type would enter the class silently — the
# wrong direction for a closure gate. This is why a CODE PR (any
# .ts/.js/.mjs/script/workflow path) still cannot use the traceability keyword:
# it is simply not on the list. `docs/` is a PREFIX (any file under it); the
# other two are EXACT/pattern paths, so e.g. `.github/workflows/*.yml` and
# `.github/CODEOWNERS.d/x` are NOT artifacts.
# Four ways to be untrustworthy, all → NOT artifact-only:
#   1. Empty/unreadable list (a broken fetch must never weaken closure).
#   2. Any row the shared validator rejects — malformed framing or an empty
#      filename. Git allows newlines and tabs INSIDE a path, and GH reports
#      filenames raw, so such a name splits one real file into several
#      well-formed-looking rows. An empty filename is likewise rejected — it
#      would otherwise vanish when command substitution strips the trailing
#      newline (order-dependent fail-open).
#   3. Any row whose OLD path ($3) is present but not in the artifact class —
#      checked for EVERY status, not just `renamed`. A rename MOVES content out
#      of the old path, and a copy introduces that content at a second path;
#      either way the old path is part of the same diff, so both ends must be
#      artifacts. This must be status-independent because split-row framing can
#      relocate a non-artifact old path onto a row whose status is not
#      `renamed`.
#   4. At or above GitHub's documented 3000-entry cap for this endpoint the
#      response may be TRUNCATED. files_rows enforces DISTINCT-new-path
#      equality with the PR's authoritative .changed_files, and this predicate
#      additionally caps the distinct-path count at 3000, so a short
#      (truncated or forged) list never reads as artifact-only.
pr_is_artifact_only() {
  local rows count paths
  rows="$(files_rows "$1")" || return 1
  [[ -n "$rows" ]] || return 1
  # The 3000-entry cap counts DISTINCT paths, matching the files_rows guard and
  # the unit GitHub caps at. Counting ROWS would wrongly deny the traceability
  # fallback to a complete list of >=3000 diff entries with fewer distinct
  # paths (a delete+add pair is two rows for one path).
  count="$(printf '%s\n' "$rows" | LC_ALL=C awk -F '\t' '{ print $2 }' | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  [[ "$count" -lt 3000 ]] || return 1
  # Both ends of every row must be in the artifact class (the new path always,
  # the old path whenever present). One failing row denies the fallback — this
  # is the anti-vacuous guard: any code path anywhere keeps check (a) closed.
  paths="$(printf '%s\n' "$rows" | LC_ALL=C awk -F '\t' '{ print $2; if ($3 != "") print $3 }')"
  [[ -n "$paths" ]] || return 1
  # #836 — here-string, never `printf … | grep -q`. This one was the most
  # dangerous site of the family: a raced pipeline INVERTS to "artifact-only"
  # (fail-OPEN), which unlocks check (a)'s non-closing traceability keyword for
  # a PR that touches code.
  ! grep -qvE '^(docs/|AGENTS\.md$|skills/.*\.md$|\.github/CODEOWNERS$)' <<<"$paths"
}

# resolve_issue_ref <pr-body> <files> — check (a)'s resolution, shared with
# the live issue lookup so checks b–e always run against the SAME issue the
# gate reported in (a). The closing keyword wins outright; the artifact-only
# traceability fallback is consulted only when no closing reference exists.
resolve_issue_ref() {
  local ref
  ref="$(parse_issue_ref "$1")"
  if [[ -z "$ref" ]] && pr_is_artifact_only "$2"; then
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

run_checks() {
  local issue_ref="" issue_ref_kind="" issue_number="" issue_repo="" issue_display="" plan_file="" wiring_found="no" close_hazards=""
  local is_micro=false is_stdcomplex=false
  local tier="unspecified"
  local files_plain="" runtime_file="" test_evidence="" files_valid="" files_ok="false"
  # Which issue-side checks actually ran (for the mode-specific PASS line) —
  # reset per call, since run_checks is invoked repeatedly by the SELF_TEST.
  B_CHECKED="no"
  D_CHECKED="no"

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
  fi

  echo "=== Pipeline Compliance Gate ==="
  if [[ "$ISSUE_ONLY" == "1" ]]; then
    echo "Issue: $ISSUE_REF (issue-only preflight — checks a/c/e skipped)"
  else
    echo "PR:   $GH_REPO#$PR_NUMBER"
  fi
  echo ""

  # a. LINKED ISSUE — closing keyword in the PR body; "owner/repo#N" (repo =
  # $GH_REPO for a bare "#N"). resolve_issue_ref is the SINGLE resolution
  # point, shared with the live issue lookup below, so check (a)'s verdict and
  # the issue that b–e actually run against can never drift apart.
  #
  # Artifact-only PRs (docs/, instruction-layer Markdown, .github/CODEOWNERS)
  # may fall back to a non-closing traceability keyword — such a PR closes no
  # runtime work, so requiring a closing keyword would force a FALSE close of
  # the linked issue. The closing form always wins when both are present, and
  # the fallback is unreachable for any PR that touches a code path
  # (pr_is_artifact_only).
  if [[ "$ISSUE_ONLY" == "1" ]]; then
    # #792 --issue-only: the target issue is an INPUT, not a PR-body parse —
    # pre-PR there is no PR body for check (a) to read. Skipped with a named
    # reason; the full-PR path below is untouched.
    issue_ref="$ISSUE_REF"
    issue_ref_kind="issue-only"
  else
    issue_ref="$(resolve_issue_ref "$PR_BODY" "$FILES")"
    issue_ref_kind="closing"
    if [[ -n "$issue_ref" && -z "$(parse_issue_ref "$PR_BODY")" ]]; then
      issue_ref_kind="traceability"
    fi
  fi
  issue_number="${issue_ref##*#}"
  issue_repo="${issue_ref%#*}"
  issue_display="#$issue_number"
  if [[ -n "$issue_ref" && -n "$issue_repo" && "$issue_repo" != "$GH_REPO" ]]; then
    issue_display="$issue_repo#$issue_number"
  fi
  if [[ "$ISSUE_ONLY" == "1" ]]; then
    echo "ℹ️  [a] Skipped: --issue-only mode evaluates the target issue's artifacts directly (no PR body exists yet)."
    echo ""
  elif [[ -n "$issue_ref" ]]; then
    # #1274 — resolve_issue_ref found the reference the author MEANT. This asks
    # the other half of the question: does the body also close something it
    # never claimed to? See scan_close_word_hazards for the two failure shapes
    # (a negation read as an instruction; an intended keyword disarmed by
    # inline code). Both were live on PR #1271 and this gate passed it.
    close_hazards="$(scan_close_word_hazards "$PR_BODY" "$issue_number")"
    if [[ -n "$close_hazards" ]]; then
      fail a "closing keyword hazard — GitHub acts on the WORDS in the PR body, not on the sentence: this body would close an issue it does not claim to close, or has disarmed the one it does."
      printf '%s\n' "$close_hazards"
      echo "      Remedy: to say an issue stays open, do NOT write a closing word next to its number — write \"leaves #N open\" or \"#N stays open\". And never wrap a real closing keyword in backticks: GitHub skips code spans, so it closes nothing."
      echo "      Invoke:  commit-workflow — rewrite the PR body, then re-run this gate."
      echo ""
    else
      if [[ "$issue_ref_kind" == "closing" ]]; then
        pass a "linked issue $issue_display (closing keyword in PR body)"
      else
        pass a "linked issue $issue_display (traceability keyword in PR body — artifact-only PR, closure not implied)"
      fi
    fi
  else
    fail a "no linked issue — PR body must carry a closing keyword (\"Fixes #N\" / \"Closes #N\" / \"Resolves #N\", or owner/repo#N / full issue URL for cross-repo) that BEGINS A LINE (a Markdown line-leading prefix — bullet, ordered-list marker, blockquote, ATX heading, task-list checkbox, compound prefixes included — or an emphasis/bold/backtick marker may precede it; a mid-sentence mention does NOT count, and can auto-close an issue on merge); a PR whose diff is ENTIRELY under docs/, entirely instruction-layer Markdown (skills/**/*.md, AGENTS.md), or entirely .github/CODEOWNERS may instead use \"Refs #N\" / \"Part of #N\" / \"Advances #N\" / \"Tracks #N\" / \"Relates to #N\"."
    echo "      Missing: issue reference in PR body."
    echo "      Invoke:  issue-scoping — run it, then reference the issue when opening the PR."
    echo ""
    echo "ℹ️  Checks b–e skipped: no linked issue to check against."
    echo ""
    return "$FAILURES"
  fi

  # Tier from issue labels.
  if grep -qx 'complexity:micro' <<<"$LABELS"; then is_micro=true; tier="micro"; fi
  if grep -qE '^complexity:(standard|complex)$' <<<"$LABELS"; then is_stdcomplex=true; tier="standard/complex"; fi
  echo "Tier: $tier (issue $issue_display)"
  echo ""

  # b. SCOPING COMMENT — `<!-- issue-scoping:` marker on the issue.
  if [[ "$is_micro" == "true" ]]; then
    echo "ℹ️  [b–e] Skipped: issue $issue_display is complexity:micro (micro-tier exemption)."
    echo ""
  else
    if has_scoping_marker "$SCOPING_COMMENT"; then
      pass b "scoping comment present on issue $issue_display (<!-- issue-scoping: marker)"
      B_CHECKED="yes"
    else
      fail b "no scoping comment on issue $issue_display — one of its comments must carry the marker \"<!-- issue-scoping:\" as its FIRST line with content, or as its LAST one set off by a blank line (it is not enough to mention it, or to show it in a quoted example, a table or a code fence — move the marker to the top of the comment or onto its own blank-line-separated footer)."
      echo "      Missing: scoping comment on the linked issue."
      echo "      Invoke:  issue-scoping — it posts the scoping comment, whose first line carries the marker."
    fi

    # c. CODE-REVIEW EVIDENCE — PR body or any PR commit message.
    EVID_TEXT="$(printf '%s\n%s\n' "$PR_BODY" "$COMMIT_MSGS")"
    if [[ "$ISSUE_ONLY" == "1" ]]; then
      # #792: needs the PR body/commits, which do not exist pre-PR. Skipped
      # with a named reason; the merge-time run still enforces it.
      echo "ℹ️  [c] Skipped: --issue-only mode (needs the PR body/commits — enforced at the required status check)."
    elif has_review_evidence "$EVID_TEXT"; then
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
      if has_clean_micro_marker "$EVID_TEXT"; then
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
      if grep -qi 'wiring' <<<"$SCOPING_COMMENT"; then wiring_found="yes"; fi
      # The Wiring alternative is file-independent, so it must be evaluated
      # BEFORE the files_ok guard: otherwise an unvalidatable list would
      # report check (d) as a plan-doc failure even when a Wiring section
      # satisfies it, asserting unprovability that is not true and breaking
      # (d)'s documented OR. The guard only names the real cause when NO plan
      # evidence is provable at all.
      if [[ -n "$plan_file" ]]; then
        pass d "plan doc in PR ($plan_file)"
        D_CHECKED="yes"
      elif [[ "$wiring_found" == "yes" ]]; then
        pass d "plan evidence: Wiring section (wiring-check table) in scoping comment"
        D_CHECKED="yes"
      elif [[ "$ISSUE_ONLY" == "1" ]]; then
        # #792: pre-PR there is no diff, so the docs/plans/*.md branch is
        # unprovable BY CONSTRUCTION. The file-independent Wiring alternative
        # was already evaluated above (and did not pass), so this is a real
        # miss — and the remedy must be the ONE that clears this mode (review
        # catch: the old text also advertised a plan doc, which --issue-only
        # can never observe, so an agent taking it would loop on the same
        # block).
        fail d "no plan evidence for issue $issue_display (complexity:standard/complex) — add a \"Wiring\" section to the scoping comment (that is the only plan evidence visible before the PR exists)."
        echo "      Missing: wiring-check table in the scoping comment."
        echo "      Invoke:  issue-scoping — the Wiring table is part of its output; writing-plans writes the docs/plans/*.md plan doc, which the merge-time run also accepts."
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
    if [[ "$ISSUE_ONLY" == "1" ]]; then
      # #792: needs the PR's diff (runtime-code detection) and its body. Both
      # do not exist pre-PR — skipped here, still enforced at merge time.
      echo "ℹ️  [e] Skipped: --issue-only mode (needs the PR's file list and body — enforced at the required status check)."
    elif [[ "$files_ok" != "true" ]]; then
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
      elif has_test_evidence "$(printf '%s\n%s\n' "$PR_BODY" "$COMMIT_MSGS")"; then
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
  if [[ "$ISSUE_ONLY" == "1" ]]; then
    # Report only what was actually EVALUATED: the micro exemption and an
    # unlabeled tier skip parts of b/d, so a fixed PASS line would claim an
    # artifact that was never read (review catch).
    if [[ "$B_CHECKED" == "yes" ]]; then
      _io_evid="(b) scoping comment present"
      if [[ "$D_CHECKED" == "yes" ]]; then
        _io_evid="$_io_evid, (d) plan evidence via the Wiring table"
      fi
      echo "✅ PIPELINE COMPLIANCE (issue-only preflight): PASS — $_io_evid. Checks a/c/e are PR-dependent and run at the required status check."
    else
      echo "✅ PIPELINE COMPLIANCE (issue-only preflight): PASS — no issue-side artifact is required at this tier (b/d exempt); checks a/c/e are PR-dependent and run at the required status check."
    fi
  else
    echo "✅ PIPELINE COMPLIANCE: PASS — scoping/review/plan/test evidence present."
  fi
  return 0
}

# ── Dry-run plan (no gh calls) ──────────────────────────────────────────────
if [[ "$DRY_RUN" == "1" && "$FAIL_ALL" != "1" ]]; then
  if [[ "$ISSUE_ONLY" == "1" ]]; then
    echo "=== Pipeline Compliance Gate — ISSUE-ONLY preflight (DRY RUN — no gh calls) ==="
    echo "Issue: $ISSUE_TARGET"
    echo ""
    echo "Would check, in order (issue-side only — no PR exists at preflight):"
    echo "  b. SCOPING COMMENT  gh api repos/<repo>/issues/<n>/comments → one comment must carry the '<!-- issue-scoping:' marker as its first content line, or as its last one set off by a blank line (a mention anywhere else does not count)"
    echo "  d. WIRING           the scoping comment's 'Wiring' section, for complexity:standard/complex only (the docs/plans/*.md branch needs the PR diff and is checked at merge time)"
    echo ""
    echo "Skipped as PR-dependent: a (PR body), c (PR body/commits), e (PR diff + body) — all enforced at the required status check."
    echo "Exemptions: complexity:micro skips b–d (identical tier exemption to the full run)."
    echo "Exit: 0 (compliant, simulated)."
    exit 0
  fi
  echo "=== Pipeline Compliance Gate (DRY RUN — no gh calls) ==="
  echo "PR:   $GH_REPO#$PR_NUMBER"
  echo ""
  echo "Would check, in order:"
  echo "  a. LINKED ISSUE      gh api repos/$GH_REPO/pulls/$PR_NUMBER   → parse PR body for closing keywords (Fixes/Closes/Resolves #N, owner/repo#N, or full https://github.com/owner/repo/issues/N URL) that BEGIN A LINE (a Markdown line-leading prefix — bullet, ordered-list marker, blockquote, ATX heading, task-list checkbox, compound prefixes included — or an emphasis/bold/backtick marker may precede; a mid-sentence mention does not count); a PR whose diff is ENTIRELY under docs/, entirely instruction-layer Markdown (skills/**/*.md, AGENTS.md), or entirely .github/CODEOWNERS may instead use a traceability keyword (Refs/Part of/Advances/Tracks/Relates to #N) — closure is not implied"
  echo "                      labels + scoping comments are fetched from the issue's OWN repo when it differs from $GH_REPO (cross-repo)"
  echo "  b. SCOPING COMMENT   gh api repos/$GH_REPO/issues/<n>/comments → the '<!-- issue-scoping:' marker as the FIRST content line of a comment, or as its LAST one set off by a blank line (an artifact, not a mention)"
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
  # real ref later in the text. Positional context (#1012): the real ref must
  # sit on its OWN line now, since a mid-sentence keyword is a mention.
  ref="$(parse_issue_ref $'resolves SLACK_APPROVAL_FILE first\nCloses #2492')"
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
  # #1012 — a MID-SENTENCE mention is not a reference. Pre-fix this vector
  # expected "$GH_REPO#42"; that looseness is exactly what let PR #968's
  # status note satisfy check (a) and would have auto-closed #949 on merge.
  expect_ref 'This fixes #42 in passing' ''
  expect_ref 'a closing keyword would falsely close #949' ''
  # A non-issue token after a keyword must not shadow a real ref — the closing
  # ref on the NEXT line is still found (the SLACK_APPROVAL_FILE regression
  # class, now judged per reference context by REFCTX).
  expect_ref $'resolves SLACK_APPROVAL_FILE first\nCloses #2492' "$GH_REPO#2492"
  expect_ref 'Closes #173.' "$GH_REPO#173"
  # #1012 — a REFERENCE CONTEXT may open with a Markdown line-leading prefix
  # (bullet, ordered marker, blockquote, ATX heading, task-list checkbox) or an
  # emphasis / bold / backtick marker, and only there. The heading /
  # ordered-list / task-list / blockquote vectors below are the regression this
  # round repairs: they resolved before the positional rule and were left
  # UNPINNED, so the narrowing went unnoticed.
  expect_ref '- Closes #173' "$GH_REPO#173"
  expect_ref '* Closes #173' "$GH_REPO#173"
  expect_ref '+ Closes #173' "$GH_REPO#173"
  expect_ref '1. Closes #173' "$GH_REPO#173"
  expect_ref '1) Closes #173' "$GH_REPO#173"
  expect_ref '> Closes #173' "$GH_REPO#173"
  expect_ref '## Closes #173' "$GH_REPO#173"
  expect_ref '###### Closes #173' "$GH_REPO#173"
  expect_ref '- [ ] Closes #173' "$GH_REPO#173"
  expect_ref '- [x] Closes #173' "$GH_REPO#173"
  expect_ref '**Closes #173**' "$GH_REPO#173"
  # #1274 — PARITY GAP, pinned rather than silently changed. REFCTX tolerates a
  # backtick prefix, so parse_issue_ref resolves this — while GitHub SKIPS inline
  # code and closes nothing. The parser stays permissive (REFCTX is a
  # byte-identical cross-script invariant shared with record-review.sh, pinned by
  # record-review.test.sh §8.13, and narrowing it here would desynchronise the
  # two copies); the GATE is where the shape is refused, by the H2 hazard below.
  expect_ref '`Closes #173`' "$GH_REPO#173"
  # #1274 — the closing-word hazard scan. Each vector is a real shape: the first
  # is PR #1271's actual heading, the second is the same body's backticked
  # intended keyword.
  expect_hazard() {
    local input="$1" intended="$2" want="$3" got
    got="$(scan_close_word_hazards "$input" "$intended")"
    if { [[ "$want" == "yes" && -n "$got" ]] || [[ "$want" == "no" && -z "$got" ]]; }; then
      printf '✅ scan_close_word_hazards(%q, %s) → hazards=%s\n' "$input" "$intended" "$want"
    else
      printf '❌ scan_close_word_hazards(%q, %s) → want hazards=%s, got %q\n' "$input" "$intended" "$want" "$got" >&2
      selffail=$((selffail + 1))
    fi
  }
  expect_hazard 'Closes #173' 173 no
  expect_hazard 'Fixes #173, Closes #173' 173 no
  # THE INCIDENT: a heading that says the issue must stay open.
  expect_hazard $'Closes #173\n\n## ⚠️ This PR does NOT close #174' 173 yes
  expect_hazard $'Closes #173\nThis also fixes #174 in passing.' 173 yes
  expect_hazard $'Closes #173\nCloses #174' 173 yes
  # H2 — the intended keyword disarmed by inline code.
  expect_hazard '`Closes #173`' 173 yes
  # Precision: an INERT mention of some OTHER issue is neither closure nor
  # disarmed intent — flagging it would be noise, and noise is how a gate gets
  # routed around.
  expect_hazard $'Closes #173\nsee `Closes #174` for how the keyword works' 173 no
  # The keyword class is a SUFFIX of ordinary words: prose that closes nothing
  # must not manufacture a hazard.
  expect_hazard $'Closes #173\nthe prefix #99 discloses #98' 173 no
  expect_ref '`Closes #173`' "$GH_REPO#173"
  # A FENCE IS NOT MODELLED — everything but inline code is treated as LIVE, so a
  # fenced close-word is REPORTED rather than stripped. Refusing a doc-only body
  # is the visible, one-edit-remedy error; modelling fences wrongly HID a live
  # closure in three dimensions (indentation, an info string with a backtick, a
  # fence line inside an HTML comment), each one a fail-open. Pinned as contract.
  expect_hazard $'Closes #173\n\n```text\nFixes #999\n```' 173 yes
  # N3 (verifier, this PR) — CommonMark forbids a backtick in a backtick fence's
  # info string, so ```Closes #173``` is a PARAGRAPH rendering as a code span:
  # inert, hence H2 — never a fence opener that hides what follows it.
  expect_hazard '```Closes #173```' 173 yes
  # ...and the mirror image stripping got wrong: a live closure AFTER such a line
  # is live too.
  expect_hazard $'Closes #173\n\n```Closes #999```\nCloses #174' 173 yes
  # N4 (verifier, this PR) — a fence-looking line inside an HTML comment is never
  # a fence, so the closure after the comment is live.
  expect_hazard $'Closes #173\n\n<!--\n```\n-->\nCloses #174' 173 yes
  # P1 (verifier, this PR) — H2 must see every reference FORM parse_issue_ref
  # accepts, not just bare #N: a backticked URL is just as disarmed.
  expect_hazard '`Closes https://github.com/daniel-ospina/agent-infra/issues/173`' 173 yes
  # #1012 r3 — the prefix + checkbox groups are REPEATABLE, so a COMPOUND
  # line-leading prefix (nested blockquote; list inside a quote) is a reference
  # context too. A single-consumption group false-BLOCKED check (a) on these
  # shapes while GitHub still auto-closes on merge; they were unpinned, which
  # is why the over-refusal was invisible.
  expect_ref '> > Closes #173' "$GH_REPO#173"
  expect_ref '> - Closes #173' "$GH_REPO#173"
  expect_ref '>> Closes #173' "$GH_REPO#173"
  expect_ref '- > Closes #173' "$GH_REPO#173"
  expect_ref '> - [ ] Closes #173' "$GH_REPO#173"
  # Anti-vacuous control for the repeatable group: consuming MORE prefixes must
  # not drag a MID-SENTENCE keyword into a reference context — the keyword must
  # still follow the marks immediately.
  expect_ref '> - This also closes #173' ''
  expect_ref '> > the prefix #173 is unrelated' ''
  expect_ref 'No issue referenced here' ''
  # Anti-vacuous control: a line-leading prefix must NOT be manufacturable out
  # of prose — a 7-hash run is not an ATX heading (the `#{1,6}` bound).
  expect_ref '####### Closes #173' ''

  # ── #720: closing parser must NOT accept traceability keywords ────────────
  # These are the RED-if-broken assertions for the artifact-only fallback. If
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

  # ── #720 + #786: artifact-only gate + combined resolution ────────────────
  expect_artifact_only() {
    local desc="$1" files="$2" want="$3" expected="${4:-}" got rc=0
    FILES_EXPECTED="$expected"
    pr_is_artifact_only "$files" || rc=$?
    FILES_EXPECTED=""
    [[ "$want" == "true" ]] && want=0 || want=1
    if [[ "$rc" == "$want" ]]; then
      printf '✅ pr_is_artifact_only(%s) → %s\n' "$desc" "$([[ $rc == 0 ]] && echo true || echo false)"
    else
      printf '❌ pr_is_artifact_only(%s) → rc=%s (expected %s)\n' "$desc" "$rc" "$want" >&2
      selffail=$((selffail + 1))
    fi
  }
  expect_artifact_only 'docs only' $'added\tdocs/plans/x.md\t\nmodified\tdocs/research/y.md\t' true
  expect_artifact_only 'docs + code' $'added\tdocs/plans/x.md\t\nmodified\tscripts/z.sh\t' false
  # #786 — instruction-layer Markdown is the SAME artifact class as docs/: it
  # ships governance/skill prose, implements no runtime work, and must not be
  # forced into a FALSE close of its issue. These read `false` before the fix
  # (the live #955 / #674 block).
  expect_artifact_only 'instruction-layer AGENTS.md only' $'modified\tAGENTS.md\t' true
  expect_artifact_only 'instruction-layer skills .md only' $'modified\tskills/foo/SKILL.md\t' true
  expect_artifact_only 'instruction-layer + docs' $'modified\tAGENTS.md\t\nadded\tdocs/plans/x.md\t' true
  # ...but the class is a POSITIVE ALLOWLIST. One code path anywhere still
  # fails closed — the anti-vacuous guard for #786: a code PR carrying only
  # "Refs #N" must NOT unlock the traceability fallback.
  expect_artifact_only 'instruction-layer + code' $'modified\tAGENTS.md\t\nmodified\tscripts/z.sh\t' false
  expect_artifact_only 'skills non-.md (skill payload)' $'modified\tskills/foo/run.sh\t' false
  expect_artifact_only 'nested AGENTS.md is NOT the instruction layer' $'modified\tsub/AGENTS.md\t' false
  # #786's headline case: `.github/CODEOWNERS` is review-routing config with no
  # executable logic — the same artifact class (the live #674 diff is CODEOWNERS
  # + docs/). Only that exact path is in the class; a workflow file next to it,
  # or a CODEOWNERS-prefixed sibling, is NOT.
  expect_artifact_only '.github/CODEOWNERS only (the #674 case)' $'modified\t.github/CODEOWNERS\t' true
  expect_artifact_only 'CODEOWNERS + docs (the live #674 diff)' $'modified\t.github/CODEOWNERS\t\nmodified\tdocs/ops/guarded-paths.md\t\nadded\tdocs/plans/x.md\t' true
  expect_artifact_only 'CODEOWNERS + workflow (still code)' $'modified\t.github/CODEOWNERS\t\nmodified\t.github/workflows/ci.yml\t' false
  expect_artifact_only 'CODEOWNERS-adjacent path is not the exact artifact' $'modified\t.github/CODEOWNERS.d/x\t' false
  # Empty/unreadable file list must NOT unlock the fallback (fails closed).
  expect_artifact_only 'empty list' '' false
  expect_artifact_only 'status-only row' $'added' false
  # Fail-closed tripwires (VGATE #720). A filename containing a newline or tab
  # breaks the row framing; an EMPTY filename can vanish when command
  # substitution strips the trailing newline (order-dependent open); a rename
  # deletes its old path. All must read as NOT artifact-only — otherwise a code
  # PR could pass check (a) with only a traceability keyword.
  expect_artifact_only 'injected newline filename' $'added\tdocs/a.md\t\nadded\t\nscripts/evil.sh' false
  expect_artifact_only 'bare newline filename' $'added\tdocs/a.md\t\nadded\t\n\t' false
  expect_artifact_only 'tab inside filename' $'added\tdocs/a.md\t\nadded\tdocs\tb.md\t' false
  expect_artifact_only 'unknown status token' $'weird\tdocs/a.md\t' false
  expect_artifact_only 'empty filename LAST row' $'added\tdocs/a.md\t\nadded\t\t' false
  expect_artifact_only 'empty filename first row' $'added\t\t\nadded\tdocs/a.md\t' false
  expect_artifact_only 'renamed docs to docs' $'renamed\tdocs/b.md\tdocs/a.md' true
  expect_artifact_only 'renamed code to docs' $'renamed\tdocs/x.md\tscripts/x.sh' false
  expect_artifact_only 'renamed without previous' $'renamed\tdocs/x.md\t' false
  # Row-by-row validation cannot catch a forgery whose injected material is
  # itself well formed. Distinct-new-path equality against .changed_files does.
  expect_artifact_only 'forged row while expected=1' $'added\tdocs/a.md\t\nadded\tdocs/plans/fake.md\t' false 1
  expect_artifact_only 'count matches expected' $'added\tdocs/a.md\t' true 1
  expect_artifact_only 'truncated list (expected=2, got 1)' $'added\tdocs/a.md\t' false 2
  # `.changed_files` counts distinct PATHS but pulls/files returns one entry per
  # DIFF ENTRY, so a delete+add on one path is two rows for one path. Comparing
  # rows would falsely block such a PR (a symlink converted to a regular file).
  expect_artifact_only 'delete+add same docs path (2 rows, 1 path)' $'removed\tdocs/x.md\t\nadded\tdocs/x.md\t' true 1
  expect_artifact_only 'delete+add same docs path, reversed order' $'added\tdocs/x.md\t\nremoved\tdocs/x.md\t' true 1
  expect_artifact_only 'delete+add same docs path, expected=2 (honest mismatch)' $'removed\tdocs/x.md\t\nadded\tdocs/x.md\t' false 2
  # The old path must be judged for EVERY status, not just `renamed`: a
  # filename containing a newline splits one real file into two well-formed
  # rows, and the non-artifact old path can land on a row labelled `added`.
  expect_artifact_only 'split-row: non-docs old path on an added row' $'renamed\tdocs/x\tdocs/old\nadded\tdocs/y\tscripts/evil.sh' false
  expect_artifact_only 'copied: docs new + code old' $'copied\tdocs/x.md\tscripts/x.sh' false
  # `unchanged` is in GitHub's documented diff-entry status enum; rejecting it
  # would wrongly block a legitimate artifact-only PR.
  expect_artifact_only 'unchanged status' $'unchanged\tdocs/a.md\t' true
  expect_artifact_only 'at the 3000-file API cap' "$(i=0; while [[ $i -lt 3000 ]]; do printf 'added\tdocs/f%s.md\t\n' "$i"; i=$((i+1)); done)" false
  expect_artifact_only 'just under the cap' "$(i=0; while [[ $i -lt 2999 ]]; do printf 'added\tdocs/f%s.md\t\n' "$i"; i=$((i+1)); done)" true
  # The cap counts DISTINCT paths, so a 3000-row list of 1500 delete+add pairs
  # is a complete, valid artifact-only list and must NOT be denied the fallback.
  expect_artifact_only '3000 rows / 1500 distinct docs paths' "$(i=0; while [[ $i -lt 1500 ]]; do printf 'removed\tdocs/f%s.md\t\nadded\tdocs/f%s.md\t\n' "$i" "$i"; i=$((i+1)); done)" true

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
  INSTRUCTION_FILES=$'modified\tskills/x/SKILL.md\t\nmodified\tAGENTS.md\t'
  CODEOWNERS_FILES=$'modified\t.github/CODEOWNERS\t\nmodified\tdocs/ops/guarded-paths.md\t'
  CODE_FILES=$'added\tscripts/z.sh\t'
  GATE_CODE_FILES=$'modified\textensions/loop-enforcer/termination.ts\t'
  # ── #786 / #1012 ACCEPTANCE VECTORS — the five that define this fix ──────
  # (1) docs-only + trace keyword: the #720 behaviour, must not regress.
  expect_resolve 'docs-only + Refs' 'Refs #631' "$DOCS_ONLY_FILES" "$GH_REPO#631"
  # (2) instruction-layer + trace keyword: NEW in #786; RED before Part 2.
  expect_resolve 'instruction-layer + Part of' 'Part of #631' "$INSTRUCTION_FILES" "$GH_REPO#631"
  # (2b) #786's headline case: the live #674 diff (CODEOWNERS + docs/) with
  #      `Refs #667` must resolve — #674 is otherwise green and must not be
  #      forced to falsely close #667.
  expect_resolve 'CODEOWNERS + docs + Refs (the #674 case)' 'Refs #667' "$CODEOWNERS_FILES" "$GH_REPO#667"
  # (3) ANTI-VACUOUS: a CODE diff with ONLY a trace keyword resolves to EMPTY,
  #     i.e. check (a) still FAILS. This is the vector that goes red if the
  #     artifact class is widened too far.
  expect_resolve 'code + Refs (must stay empty)' 'Refs #949' "$GATE_CODE_FILES" ''
  # (4) #1012 LIVE REGRESSION: a code diff whose body only MENTIONS a closing
  #     keyword resolves to EMPTY. This sentence is the one that satisfied
  #     check (a) on PR #968. RED before Part 1.
  expect_resolve 'code + mid-sentence closing mention' \
    'Fixing (a) is an authoring decision — a closing keyword would falsely close #949.' \
    "$CODE_FILES" ''
  # (5) a normal own-line closing keyword still resolves (no regression).
  expect_resolve 'own-line Closes' $'Prose preamble that references nothing\n\nCloses #631' "$CODE_FILES" "$GH_REPO#631"
  # The closing form must win even on an artifact-only PR, and must work even
  # when the PR touches code (closure semantics are never weakened for code PRs).
  expect_resolve 'closing beats trace (docs-only)' $'Refs #631\nCloses #701' "$DOCS_ONLY_FILES" "$GH_REPO#701"
  expect_resolve 'closing + code' $'Refs #631\nCloses #701' "$CODE_FILES" "$GH_REPO#701"
  expect_resolve 'trace + code' 'Refs #631' "$CODE_FILES" ''
  expect_resolve 'no ref at all' 'nothing here' "$CODE_FILES" ''
  # ── #1012: the closing match is POSITIONAL, and the pattern is shared with
  # record-review.sh::closing_issue_refs (its §8.11 pins the same class). A
  # keyword buried inside a word or a sentence is a mention, not a reference.
  # The parity scan that misreads prose lives in record-review.sh and is pinned
  # by its §8.11/§8.14; here the boundaries that matter are the positional ones.
  expect_ref 'prefixes #42' ''
  expect_ref 'bugfixes #42' ''
  expect_ref 'The prefix #42 is unrelated.' ''
  # The TRACE class is positional too, so a mid-word / mid-sentence substring
  # must not resolve — while a real reference context does (pinned above).
  expect_trace 'prefs #42' ''
  expect_trace 'preferences #42' ''
  expect_trace 'a sentence about refs #42' ''

  # ── #991: the scoping marker must be an ARTIFACT, not a mention ──────────
  # Check (b) is the only enforcement that issue-scoping ran for a non-micro
  # issue, and it used to be `grep -qF '<!-- issue-scoping:'` — satisfied by any
  # comment that merely MENTIONED the marker. The `prose` vectors below are the
  # point of this block: without them the fix pins nothing, and they are the
  # live defect, not a hypothetical. The first one is the literal sentence from
  # #786 that falsely satisfied (b) on #786 itself while stating that a
  # DIFFERENT issue had no scoping comment.
  expect_scoping() {
    local desc="$1" text="$2" want="$3" got
    if has_scoping_marker "$text"; then got=true; else got=false; fi
    if [[ "$got" == "$want" ]]; then
      printf '✅ has_scoping_marker(%s) → %s\n' "$desc" "$got"
    else
      printf '❌ has_scoping_marker(%s) → %s (expected %s)\n' "$desc" "$got" "$want" >&2
      selffail=$((selffail + 1))
    fi
  }
  # Real artifact: the marker is at column 0 of the comment's first line (this
  # is the head of the #949 scoping comment, quoted verbatim).
  expect_scoping 'genuine artifact (marker on line 1)' \
    '<!-- issue-scoping: 2026-09-13 · #949 · consolidated duplication remediation -->

# Scoping — #949' true
  # POSITION IS THE CONTRACT, so a marker that is neither the comment's first
  # line with content nor a blank-line-separated footer is NOT an artifact —
  # however well-formed it looks. This read `true` under the fence parser, which
  # only asked whether the marker began a line; under a positional rule it is
  # false because the preamble crowds it. Measured, not assumed: across the
  # repo's 235 marker-bearing comments the marker is first in 223 and a
  # blank-line-separated last line in 2 (both #783); the other 10 are prose,
  # tables or fenced examples.
  expect_scoping 'marker after a crowded prose preamble (not the first line)' \
    'Some preamble about the issue.
<!-- issue-scoping: 2026-09-14 · #991 · x -->' false
  # The FOOTER shape is real work, not a hypothetical: #783's two artifacts
  # ("Scope confirmed" and "Plan complete") carry the marker on their last line,
  # set off by a blank line, and #783 carries two of them. #783's PR (#873)
  # merged 2026-09-13, before this fix, so no live PR was at stake — but a
  # first-line-only rule silently invalidates real artifacts, and would fail
  # closed on any future PR whose issue carries one. The blank line above the
  # marker is what keeps this from also accepting the crowded mention shapes.
  expect_scoping 'genuine artifact (marker as the LAST line, after a blank line) — the #783 shape' \
    '*Artifact:* docs/scoping/2026-09-12-issue-783-census/SCOPE-ARTIFACT.md

<!-- issue-scoping: v5.1 double diamond + verify -->' true
  # ...but the blank line is load-bearing. Crowded against the line above, the
  # same text is indistinguishable from a mention and must stay false.
  expect_scoping 'marker as the last line, crowded (no blank line above)' \
    'See the census artifact for the full picture.
<!-- issue-scoping: v5.1 double diamond + verify -->' false
  # Leading BLANK lines are tolerated: the rule is the first line WITH CONTENT,
  # so a comment that opens with a newline still carries the artifact.
  expect_scoping 'genuine artifact (marker after leading blank lines)' \
    '

<!-- issue-scoping: 2026-09-14 · #991 · x -->
## Confirmed Problem' true
  # LEADING ATX HEADINGS are tolerated, because the producer emits BOTH shapes.
  # A STRICT first-line rule rejected the second shape outright and FOUR genuine
  # artifacts already in this repo have it (#729, #843, #857, #858) — the check
  # would have invalidated real work while claiming to sharpen a rule. Verified
  # against the live comments, not constructed.
  expect_scoping 'genuine artifact (heading, then the marker) — the #843 shape' \
    '## Scope — resolve the merge result from the REST API

<!-- issue-scoping: 2026-09-14 (standard) -->

**Tier:** complexity:standard

### Problem (confirmed, re-derived)' true
  # A heading followed by PROSE is a discussion comment, not an artifact — the
  # heading is skipped, and the first real content line is prose, so it must be
  # the marker and is not. This is the #674/#680/#793 shape.
  # The REAL #674 shape, reduced: an artifact-status comment that OPENS with a
  # heading and then MENTIONS the marker inside a sentence. It contains the
  # marker, so the pre-fix substring matcher accepted it — this vector is
  # therefore non-vacuous in the direction that matters. (An earlier version of
  # this vector omitted the marker entirely, which made it indistinguishable
  # from the `no marker at all` guard and pinned nothing — caught in review.)
  expect_scoping 'heading, then prose CALLING the marker (not an artifact) — the #674 shape' \
    $'## ⛔ Premise verification: PARTLY TRUE — the artifact enforces nothing\n\nThe defect is that the PR does not disclose it: | b. SCOPING COMMENT (`<!-- issue-scoping:` marker) | — |' false
  # A FENCED example that opens with a heading: line 1 is ```markdown, which is
  # neither blank nor a heading, so it must itself be the marker. Closing the
  # heading allowance one level down.
  expect_scoping 'fenced example opening with a heading' \
    '```markdown
## Scope
<!-- issue-scoping: 2026-01-01 · #1 · x -->
```' false
  # ❌ THE LIVE REPRODUCTION — the opening of #786's first comment, which is
  # what actually satisfied check (b) on #786. Quoted from the sentence as far
  # as "have one"; the comment continues ", an epic-recorded deviation". The
  # vector is truncated for readability, not altered — the live comment was
  # re-checked and behaves identically (pre-fix true, post-fix false).
  expect_scoping 'prose mentioning the marker (#786, the live defect)' \
    "Once (a) is satisfiable, this PR also trips (b) (no \`<!-- issue-scoping:\` comment on #922 — 0 comments; 0/7 open #917 children have one)." false
  # Prose that asserts the artifact is MISSING must never satisfy the check.
  expect_scoping 'prose asserting absence' \
    'There is no <!-- issue-scoping: marker on this issue.' false
  expect_scoping 'prose quoting the marker inline' \
    'The gate greps for <!-- issue-scoping: and nothing else.' false
  # A fenced code block that quotes the marker mid-line is still a mention.
  expect_scoping 'marker quoted inside code span' \
    'Run: grep -qF "<!-- issue-scoping:" <<<"$SCOPING_COMMENT"' false
  # Blockquote: the line starts with `>`, not with the marker.
  expect_scoping 'marker inside a blockquote' \
    '> <!-- issue-scoping: quoted, not posted -->' false
  # INDENTED ON THE FIRST LINE: must FAIL. An earlier revision tolerated this,
  # on the reasoning that nothing precedes the first line so indentation cannot
  # mean "inside a code block". That was WRONG: GFM renders a first line
  # indented >=4 columns as an INDENTED CODE BLOCK, which displays the marker
  # text — a mention, not a hidden artifact. The 2-space form below is harmless
  # in rendering terms but is not the producer's form either, and every real
  # artifact in this repo is at column 0, so the rule is column 0 for all of
  # them. All four parser generations rejected the >=4 forms; the deletion had
  # re-admitted them.
  expect_scoping 'marker indented 2 spaces on the first line' \
    '  <!-- issue-scoping: indented -->' false
  expect_scoping 'marker indented 4 spaces on the first line (indented code block)' \
    '    <!-- issue-scoping: 2026-01-01 · #1 · x -->' false
  expect_scoping 'marker tab-indented on the first line (indented code block)' \
    '	<!-- issue-scoping: 2026-01-01 · #1 · x -->' false
  # A marker at column 0 INSIDE a fence is still a mention — and this is the
  # realistic one: issue-scoping/SKILL.md documents the posting form as a
  # ```bash fence with the marker at column 0, so quoting the skill's own
  # instructions false-passed under the anchored-only version.
  expect_scoping 'marker at column 0 inside a fence' \
    'Comment explaining the gate:

```bash
<!-- issue-scoping: 2026-01-01 · #1 · example -->
```' false
  expect_scoping 'marker inside a tilde fence' \
    '~~~
<!-- issue-scoping: 2026-01-01 · #1 · x -->
~~~' false
  # NESTED / MIXED fences — a boolean toggle false-passed all three of these.
  # The first is the canonical way to quote a fenced block inside a fenced
  # block, so it is a realistic quoting form, not a contrived one.
  expect_scoping '4-backtick outer, 3-backtick inner (nested)' \
    '````markdown
```bash
<!-- issue-scoping: 2026-01-01 · #1 · x -->
```
````' false
  expect_scoping 'tilde outer, backtick inner' \
    '~~~
```
<!-- issue-scoping: 2026-01-01 · #1 · x -->
```
~~~' false
  expect_scoping 'backtick outer, tilde inner' \
    '```
~~~
<!-- issue-scoping: 2026-01-01 · #1 · x -->
~~~
```' false
  # A closer may be followed only by whitespace; this one does not close, so
  # the marker stays inside the fence.
  expect_scoping 'invalid closer (trailing text)' \
    '```
<!-- issue-scoping: 2026-01-01 · #1 · x -->
``` closing' false
  # INDENTATION. CommonMark allows a fence at most 3 columns of indentation
  # (tab = next multiple of 4). The character/length rule alone false-PASSED
  # the first vector below — a fail-OPEN — because the 4-space-indented ``` was
  # read as a closer, exposing a marker GitHub renders inside <pre>.
  expect_scoping '4-space-indented closer inside a fence (fail-open guard)' \
    '```markdown
Example:
    ```bash
    echo hi
    ```
<!-- issue-scoping: 2026-01-01 · #1 · x -->' false
  expect_scoping 'tab-indented closer inside a fence (fail-open guard)' \
    '```
<!-- issue-scoping: 2026-01-01 · #1 · x -->
	```
<!-- issue-scoping: 2026-01-01 · #1 · still in fence -->' false
  # An over-indented opener is paragraph text, not a fence — but that no longer
  # matters: the marker below it is not the comment's FIRST line, so it is not
  # an artifact either way. The parser needed a rule for this case; the
  # positional check does not, which is the point of the revision.
  expect_scoping 'over-indented opener, marker below it (not first line)' \
    'Preamble:
    ```
<!-- issue-scoping: 2026-01-01 · #1 · x -->' false
  expect_scoping 'tab-indented opener, marker below it (not first line)' \
    'Preamble:
	```
<!-- issue-scoping: 2026-01-01 · #1 · x -->' false
  # Boundary: 3 columns is still a fence; 4 is not.
  expect_scoping 'fence indented 3 spaces containing the marker' \
    '   ```
<!-- issue-scoping: 2026-01-01 · #1 · x -->' false
  expect_scoping 'over-indented fence, marker below it (not first line)' \
    '    ```
<!-- issue-scoping: 2026-01-01 · #1 · x -->' false
  # ...but a genuine artifact FOLLOWED by a fence must still PASS. The producer
  # posts the marker first, so fence state can never hide a real one — this is
  # the no-regression guard for the fence rule.
  expect_scoping 'genuine marker, fence later in the comment' \
    '<!-- issue-scoping: 2026-09-14 · #991 · x -->

```bash
echo hi
```' true
  expect_scoping 'empty comment text' '' false
  expect_scoping 'no marker at all' 'Just a normal comment.' false
  # The real #991 scoping comment head (posted) must PASS.
  expect_scoping 'real #991 scoping comment' \
    '<!-- issue-scoping: 2026-09-14 · #991 · check (b) is a bare-substring fail-open -->

# Scoping — #991' true
  # MULTI-COMMENT: each comment is its own record (0x1e), and the marker must be
  # the first line of ONE of them — not of the thread. Testing only the
  # concatenation's first line was a regression: #883's genuine artifact is
  # comment 3, after two discussion comments, and it failed. The retrospective
  # path is exactly when an artifact lands late, so this is the load-bearing
  # case rather than an edge.
  expect_scoping 'genuine artifact in the SECOND comment' \
    $'first comment: no artifact, just discussion.\n\x1e<!-- issue-scoping: 2026-09-14 · #991 · x -->\n\n## Plan' true
  expect_scoping 'real #883 shape — artifact is comment 3 of 3' \
    $'This is fixed by #973, filed independently.\n\x1eanother discussion comment.\n\x1e<!-- issue-scoping: 2026-09-14 (standard, retrospective) -->\n\n## Plan' true
  expect_scoping 'marker crowded in the SECOND comment (not its first line)' \
    $'plain first comment.\n\x1eSome preface.\n<!-- issue-scoping: 2026-09-14 · #991 · x -->' false
  expect_scoping 'mention in a later comment, artifact in none' \
    $'first comment discussing the `<!-- issue-scoping:` marker form.\n\x1esee above for the marker `<!-- issue-scoping:` — no artifact here.' false

  # ── #836: broken-pipe regression (checks c/e must not false-negate) ───────
  # See the `has_review_evidence` rationale block above. The bug was a RACE, so
  # a single run cannot pin it: every assertion below repeats REPS times and
  # requires EVERY run to agree. Pre-fix, the end-to-end half of this block was
  # RED on ~75–80 % of runs — re-running the check is what "fixed" it in CI,
  # which is exactly the flake this pins out.
  REPS=25
  big_filler="$(LC_ALL=C awk 'BEGIN { for (i = 0; i < 1200; i++) print "lorem ipsum dolor sit amet consectetur adipiscing elit" }')"
  # The matching token sits on the FIRST line = maximum race pressure: `grep -q`
  # matches immediately while a naive writer is still writing the remaining
  # ~64 KB of evidence text.
  big_review="review recorded (code-review dispatched on the head commit)
$big_filler"
  big_tests="test suite green: 114/114 passed
$big_filler"
  big_absent="$big_filler"

  # The fixture must exceed PIPE_BUF by orders of magnitude — assert it, so the
  # test cannot silently degrade into an input too small to race.
  for _f in "$big_review" "$big_tests" "$big_absent"; do
    _fb="$(printf '%s' "$_f" | wc -c | tr -d ' ')"
    if [[ "$_fb" -le 65536 ]]; then
      printf '❌ SELF-TEST SETUP (#836): evidence fixture is only %s bytes (must exceed 65536)\n' "$_fb" >&2
      selffail=$((selffail + 1))
    fi
  done

  assert_repeated() {
    local name="$1" fn="$2" text="$3" want="$4" i got bad=0 wantdesc misdesc
    if [[ "$want" == "0" ]]; then wantdesc="present"; misdesc="absent"; else wantdesc="absent"; misdesc="present"; fi
    for ((i = 0; i < REPS; i++)); do
      if "$fn" "$text"; then got=0; else got=1; fi
      [[ "$got" == "$want" ]] || bad=$((bad + 1))
    done
    if [[ "$bad" -eq 0 ]]; then
      printf '✅ %s: %s/%s runs reported %s (%s-byte input)\n' \
        "$name" "$REPS" "$REPS" "$wantdesc" "$(printf '%s' "$text" | wc -c | tr -d ' ')"
    else
      printf '❌ %s: %s/%s runs disagreed — evidence reported %s (BROKEN-PIPE regression, #836)\n' \
        "$name" "$bad" "$REPS" "$misdesc" >&2
      selffail=$((selffail + 1))
    fi
  }

  # Positive (the regression) + negative control (so the positive cannot pass
  # vacuously — the same >64 KB filler with no token must read as absent).
  assert_repeated '#836 (c) large evidence present → present' has_review_evidence "$big_review" 0
  assert_repeated '#836 (e) large evidence present → present' has_test_evidence "$big_tests" 0
  assert_repeated '#836 (c) large evidence with NO token → absent' has_review_evidence "$big_absent" 1
  assert_repeated '#836 (e) large evidence with NO token → absent' has_test_evidence "$big_absent" 1

  # End-to-end through the REAL run_checks — the production path the CI gate
  # takes, with a complexity:standard issue and every artifact in place except
  # a test FILE (so check (e) itself must match the >64 KB body, not the diff).
  # Pre-fix this produced 1–2 failures on most runs although nothing was missing.
  big_body="Closes #1
code-review dispatched on the head commit
test suite green: 114/114 passed
$big_filler"
  e2e_bad=0
  E2E_LOG="$(mktemp "${TMPDIR:-/tmp}/pipeline-836-e2e.XXXXXX")"
  for ((i = 0; i < REPS; i++)); do
    PR_BODY="$big_body"
    COMMIT_MSGS="$big_body"
    LABELS="complexity:standard"
    SCOPING_COMMENT="<!-- issue-scoping: 2026-09-11 (standard) -->
### Wiring
| Interface | Consumer |"
    FILES=$'added\textensions/example/sample.ts\t'
    FILES_EXPECTED=1
    FAILURES=0
    run_checks > "$E2E_LOG" 2>&1 || true
    [[ "$FAILURES" -eq 0 ]] || e2e_bad=$((e2e_bad + 1))
  done
  if [[ "$e2e_bad" -eq 0 ]]; then
    printf '✅ #836 run_checks end-to-end: %s/%s runs with a %s-byte PR body → 0 failures\n' \
      "$REPS" "$REPS" "$(printf '%s' "$big_body" | wc -c | tr -d ' ')"
  else
    printf '❌ #836 run_checks end-to-end: %s/%s runs reported failures with all evidence present (BROKEN-PIPE regression)\n' \
      "$e2e_bad" "$REPS" >&2
    grep -E '❌ \[[abcd]\]|❌ \[e\]' "$E2E_LOG" | head -3 >&2 || true
    selffail=$((selffail + 1))
  fi
  rm -f "$E2E_LOG"

  # ── #836 indicator 2: the idiom must not come back ──────────────────────
  # Deliberately NOT pinned here. #863 landed `scripts/check-no-sigpipe-grep.sh`
  # — a repo-wide guard for this same `printf/echo | grep -q` SIGPIPE idiom
  # whose SCAN_DIRS include `scripts/`, so THIS file is in its scan set — plus
  # `tests/sigpipe-grep/run.sh`, which pins that guard's detection of the joined
  # (`-q`), combined (`-Fqx`) and `--quiet` spellings, its negation controls
  # (here-string, `case`, a non-quiet `| grep`), the `\`-continued form, comment
  # exclusion, and the guard's own self-scan. A second copy of that scan living
  # in this self-test would be a second source of truth for one idiom, free to
  # drift from the guard that owns it, so the local pin was removed rather than
  # duplicated (#841, #863).
  #
  # The handover is NOT total, and the difference is recorded instead of
  # glossed: the repo-wide guard's matcher is narrower than the pin deleted
  # here. It requires `grep` immediately after the pipe (so a post-pipe env
  # prefix — `printf … | LC_ALL=C grep -q x` — is a MISS), knows only the
  # `printf`/`echo` producers (so a `cat file | grep -q x` is a MISS; its header
  # scopes non-builtin producers out deliberately), and looks for the quiet flag
  # before the pattern (so `grep x -q` is a MISS). No live occurrence of those
  # three spellings exists on this head, so nothing regresses today — the gap is
  # tracked in issue #877, together with the fact that run.sh has no separated
  # `grep -i -q` fixture (the guard's has_quiet() does detect that spelling; the
  # suite simply does not pin it).
  #
  # The reproduction half is now closed: #876 (`f9909b2`, issue #861) wired the
  # guard into `.husky/pre-commit` and, with its suite, into CI (`ci.yml` job
  # `sigpipe-grep`, which runs both). A reintroduced `printf`/`echo | grep -q`
  # site in one of the forms the guard covers therefore fails a check instead of
  # merging green; the three spellings above stay unenforced until #877.
  #
  # The behavioural half of #836 (large-input regression vectors below, incl. the
  # fail-OPEN `pr_is_artifact_only` site) is unaffected and still lives here, because
  # no repo-wide grep guard can express it.
  #
  # `${BASH_SOURCE[0]:-$0}` — under `set -u` BASH_SOURCE is unset for a
  # stdin/`eval` invocation, which used to abort the whole self-test before the
  # #792 vectors ran (review catch). The #792 CLI vectors below re-enter this
  # script through it.
  SELF_SRC="${BASH_SOURCE[0]:-$0}"

  # ── #836 fail-OPEN site: pr_is_artifact_only at a racy size ─────────────────
  # pr_is_artifact_only's `! printf … | grep -qvE '^(docs/|AGENTS\.md$|skills/.*\.md$|\.github/CODEOWNERS$)'` did not merely
  # false-block: on a raced pipeline it INVERTED to "artifact-only" (measured
  # ~88% of runs at ~89 KB), which unlocks check (a)'s non-closing
  # traceability keyword for a code PR. The small `expect_artifact_only` vectors
  # cannot race, so the site has its own large-input behavioural pin: a >64 KB
  # row list whose FIRST row is a non-artifact path must read NOT artifact-only, on
  # EVERY run.
  # ~84 KB: the guard below asserts >65536, and a row is ~32 bytes, so the row
  # count must clear 2028 with margin.
  big_paths="$(printf 'added\tscripts/evil.sh\t\n'; i=0; while [[ $i -lt 2600 ]]; do printf 'added\tdocs/lorem-filler-%s.md\t\n' "$i"; i=$((i+1)); done)"
  big_paths_bytes="$(printf '%s' "$big_paths" | wc -c | tr -d ' ')"
  if [[ "$big_paths_bytes" -le 65536 ]]; then
    printf '❌ SELF-TEST SETUP (#836): pr_is_artifact_only fixture is only %s bytes (must exceed 65536)\n' "$big_paths_bytes" >&2
    selffail=$((selffail + 1))
  fi
  docs_open_bad=0
  for ((i = 0; i < REPS; i++)); do
    FILES_EXPECTED=""
    if pr_is_artifact_only "$big_paths"; then docs_open_bad=$((docs_open_bad + 1)); fi
  done
  if [[ "$docs_open_bad" -eq 0 ]]; then
    printf '✅ #836 pr_is_artifact_only fail-OPEN site: %s/%s runs kept a non-artifact start as NOT artifact-only (%s-byte list)\n' \
      "$REPS" "$REPS" "$big_paths_bytes"
  else
    printf '❌ #836 pr_is_artifact_only fail-OPEN site: %s/%s runs reported a non-artifact list as artifact-only (BROKEN-PIPE regression — check (a) could be dodged on a code PR)\n' \
      "$docs_open_bad" "$REPS" >&2
    selffail=$((selffail + 1))
  fi
  FILES_EXPECTED=""

  # ── #792: --issue-only CLI/env surface (review catch: the mode's own entry
  # point had NO coverage — a mutant that broke the target mapping left this
  # block green). The mapping is pinned as a pure function, and the argv/env
  # contract as subprocess exit codes; every case below is offline (exit-2
  # paths never reach gh, and the one success case is DRY_RUN).
  expect_io_ref() {
    local input="$1" expected="$2" got
    got="$(resolve_issue_only_ref "$input")"
    if [[ "$got" == "$expected" ]]; then
      printf '✅ resolve_issue_only_ref(%q) → %q\n' "$input" "$got"
    else
      printf '❌ resolve_issue_only_ref(%q) → %q (expected %q)\n' "$input" "$got" "$expected" >&2
      selffail=$((selffail + 1))
    fi
  }
  expect_io_ref '42' "$GH_REPO#42"
  expect_io_ref 'daniel-ospina/agent-infra#42' 'daniel-ospina/agent-infra#42'
  expect_io_ref 'daniel-ospina/swarm#2492' 'daniel-ospina/swarm#2492'

  # Subprocess vectors. SELF_TEST is forced to 0 in the child (else the child
  # re-enters this block and recurses); the success case is DRY_RUN, so no gh.
  cli_rc() {
    local rc=0
    PIPELINE_COMPLIANCE_SELF_TEST=0 PIPELINE_COMPLIANCE_DRY_RUN="${CLI_DRY_RUN:-0}" \
      PIPELINE_COMPLIANCE_ISSUE_ONLY="${CLI_IO_ONLY:-0}" PIPELINE_COMPLIANCE_ISSUE="${CLI_IO_ISSUE:-}" \
      GH_REPO="$GH_REPO" bash "$SELF_SRC" "$@" >"$CLI_LOG" 2>&1 || rc=$?
    printf '%s' "$rc"
  }
  expect_cli_rc() {
    local desc="$1" want="$2" got; shift 2
    got="$(cli_rc "$@")"
    if [[ "$got" == "$want" ]]; then
      printf '✅ #792 CLI: %s → exit %s\n' "$desc" "$got"
    else
      printf '❌ #792 CLI: %s → exit %s (expected %s)\n' "$desc" "$got" "$want" >&2
      sed -n '1,4p' "$CLI_LOG" >&2 || true
      selffail=$((selffail + 1))
    fi
  }
  # An exit code alone does not pin an argv guard: 2 is ALSO the contract value
  # for "could not run", so a guard whose body was deleted still returned 2 —
  # through the live path's unauthenticated `gh`, i.e. the very code the vector
  # expects (review catch, verified against a mutant). The rejecting vectors
  # therefore (a) run with DRY_RUN=1, so a fall-through reaches the plan and
  # exits 0 instead of shelling out to `gh` — they stay offline on a
  # regression too — and (b) assert the DIAGNOSTIC, not just the code.
  expect_cli_err() {
    local desc="$1" want="$2" want_txt="$3" got; shift 3
    got="$(cli_rc "$@")"
    if [[ "$got" == "$want" ]] && grep -qF -- "$want_txt" "$CLI_LOG"; then
      printf '✅ #792 CLI: %s → exit %s with the "%s" diagnostic\n' "$desc" "$got" "$want_txt"
    else
      printf '❌ #792 CLI: %s → exit %s (expected %s) and/or the "%s" diagnostic was missing — the rejection is not pinned\n' \
        "$desc" "$got" "$want" "$want_txt" >&2
      sed -n '1,6p' "$CLI_LOG" >&2 || true
      selffail=$((selffail + 1))
    fi
  }
  CLI_LOG="$(mktemp "${TMPDIR:-/tmp}/pipeline-792-cli.XXXXXX")"
  CLI_DRY_RUN=1; CLI_IO_ONLY=0; CLI_IO_ISSUE=""
  expect_cli_err 'no target'                        2 'needs an issue' --issue-only
  expect_cli_err 'malformed target'                  2 'must be an issue number or owner/repo#N' --issue-only 'not a target'
  expect_cli_err 'surplus argument after the target'  2 'takes exactly one issue target' --issue-only 792 999
  expect_cli_err 'flag AFTER a positional (misorder)' 2 'must be the first argument' 792 --issue-only
  expect_cli_err 'malformed owner/repo#N target'      2 'must be an issue number or owner/repo#N' --issue-only 'a/b#nope'
  CLI_DRY_RUN=1; CLI_IO_ONLY=1; CLI_IO_ISSUE='a b'
  expect_cli_err 'ENV form with a malformed target'   2 'must be an issue number or owner/repo#N'
  # The env seam and argv must not disagree silently (review catch): the
  # positional used to be dropped, and an argv target used to override the env
  # one. Both are usage errors now.
  CLI_DRY_RUN=1; CLI_IO_ONLY=1; CLI_IO_ISSUE='42'
  expect_cli_err 'ENV target + positional argument'   2 'pass exactly one target' 792
  expect_cli_err 'ENV target + argv --issue-only'     2 'two issue targets' --issue-only 999
  CLI_DRY_RUN=1; CLI_IO_ONLY=1; CLI_IO_ISSUE='123'
  expect_cli_rc 'ENV form (ISSUE_ONLY + ISSUE), dry run' 0
  if grep -q 'Issue: 123' "$CLI_LOG"; then
    printf '✅ #792 CLI: the documented ENV form (PIPELINE_COMPLIANCE_ISSUE_ONLY=1 + PIPELINE_COMPLIANCE_ISSUE=123) actually resolves the target\n'
  else
    printf '❌ #792 CLI: the documented ENV form did not resolve its target — exit 0 but no "Issue: 123" in the output\n' >&2
    sed -n '1,6p' "$CLI_LOG" >&2 || true
    selffail=$((selffail + 1))
  fi
  # (ISSUE_TARGET is UNUSED when ISSUE_ONLY=0, so an exported PIPELINE_COMPLIANCE_ISSUE
  # must not turn a normal PR run into a usage error — review cycle 3 catch.)
  CLI_DRY_RUN=1; CLI_IO_ONLY=0; CLI_IO_ISSUE='42'
  expect_cli_rc 'PR path with PIPELINE_COMPLIANCE_ISSUE set in the env (unused there)' 0 123
  CLI_DRY_RUN=0; CLI_IO_ONLY=0; CLI_IO_ISSUE=""
  rm -f "$CLI_LOG"
  unset CLI_LOG CLI_DRY_RUN CLI_IO_ONLY CLI_IO_ISSUE 2>/dev/null || true

  # ── #792: --issue-only preflight vectors ────────────────────────────────
  # The mode must enforce the SAME artifacts the merge gate enforces, by the
  # same means: (b) the scoping marker, (d) the file-independent Wiring branch,
  # with identical tier exemptions — and it must SKIP a/c/e rather than
  # reporting them.
  run_io() {
    ISSUE_ONLY=1
    ISSUE_REF="$GH_REPO#1"
    LABELS="$1"
    SCOPING_COMMENT="$2"
    PR_BODY=""; COMMIT_MSGS=""; FILES=""; FILES_EXPECTED=""
    FAILURES=0
    IO_LOG="$(mktemp "${TMPDIR:-/tmp}/pipeline-792-io.XXXXXX")"
    # summarize() is captured too, so a vector can assert the preflight's PASS
    # line — the only reader of B_CHECKED/D_CHECKED. Without it, deleting
    # `B_CHECKED="yes"`/`D_CHECKED="yes"` left every vector green while a
    # standard issue that passed on both artifacts was reported as "no
    # issue-side artifact is required at this tier" (review catch: the
    # report-only-what-was-evaluated claim was unpinned).
    { run_checks || true; summarize || true; } > "$IO_LOG" 2>&1
    IO_FAILURES="$FAILURES"
    ISSUE_ONLY=0
  }
  io_report() {
    local desc="$1" ok="$2"
    if [[ "$ok" == "1" ]]; then
      printf '✅ #792 issue-only: %s\n' "$desc"
    else
      printf '❌ #792 issue-only: %s\n' "$desc" >&2
      grep -E '❌ \[|ℹ️  \[' "$IO_LOG" >&2 || true
      selffail=$((selffail + 1))
    fi
    # $IO_LOG is NOT removed here — a vector asserts several things about the
    # same run. Each vector ends with io_cleanup.
  }
  io_cleanup() { rm -f "$IO_LOG"; }

  WIRING_SCOPING="<!-- issue-scoping: 2026-09-11 (standard) -->
### Wiring
| Interface | Consumer |"
  MARKER_ONLY="<!-- issue-scoping: 2026-09-11 (standard) -->"
  NO_MARKER="this issue has no scoping comment marker at all"

  # 1. micro → identical tier exemption to the full run (b–e skipped, 0 failures).
  run_io "complexity:micro" ""
  io_report 'micro issue with no artifacts → 0 failures (b–e exempt)' \
    "$([[ "$IO_FAILURES" -eq 0 ]] && echo 1 || echo 0)"
  # ...and the PASS line must say the tier is exempt, not that (b)/(d) were read.
  io_report 'micro PASS line reports the tier exemption, not a (b)/(d) read' \
    "$(grep -qF 'PASS — no issue-side artifact is required at this tier (b/d exempt)' "$IO_LOG" && echo 1 || echo 0)"
  io_cleanup

  # 2. standard + marker + Wiring → 0 failures, and a/c/e each named as
  #    skipped (all three are PR-dependent, so the issue-only mode must say so
  #    rather than leave them unaccounted for).
  run_io "complexity:standard" "$WIRING_SCOPING"
  io_report 'standard + marker + Wiring → 0 failures' \
    "$([[ "$IO_FAILURES" -eq 0 ]] && echo 1 || echo 0)"
  # The PASS line must name BOTH artifacts it actually read — this is what makes
  # B_CHECKED/D_CHECKED load-bearing: clearing either flag on the passing path
  # now fails this vector instead of silently downgrading the reported evidence.
  io_report 'standard PASS line names (b) and (d) as the artifacts actually read' \
    "$(grep -qF 'PASS — (b) scoping comment present, (d) plan evidence via the Wiring table' "$IO_LOG" && echo 1 || echo 0)"
  IO_SKIPS="$(grep -cE '\[[ace]\] Skipped: --issue-only mode' "$IO_LOG" || true)"
  io_report 'checks a/c/e are SKIPPED with a named reason (3 skip lines)' \
    "$([[ "$IO_SKIPS" -eq 3 ]] && echo 1 || echo 0)"
  io_cleanup

  # 3. standard + marker, NO Wiring → the real pre-PR miss: exactly 1 failure
  #    (d), naming the local remedy — and NOT the "cannot validate the PR's file
  #    list" text, which would name a cause that is false in this mode.
  run_io "complexity:standard" "$MARKER_ONLY"
  io_report 'standard + marker, no Wiring → 1 failure' \
    "$([[ "$IO_FAILURES" -eq 1 ]] && echo 1 || echo 0)"
  IO_REMEDY="$(grep -c 'no plan evidence for issue' "$IO_LOG" || true)"
  IO_LISTCAUSE="$(grep -c "cannot validate the PR's file list" "$IO_LOG" || true)"
  io_report 'the (d) failure names the LOCAL remedy, not the unprovable-list cause' \
    "$([[ "$IO_REMEDY" -eq 1 && "$IO_LISTCAUSE" -eq 0 ]] && echo 1 || echo 0)"
  io_cleanup

  # 4. standard, NO marker, Wiring present → the marker is still required (b),
  #    while d passes on the Wiring branch.
  run_io "complexity:standard" "$NO_MARKER### Wiring"
  IO_B="$(grep -c '❌ \[b\]' "$IO_LOG" || true)"
  io_report 'standard without the scoping marker → 1 failure (b)' \
    "$([[ "$IO_FAILURES" -eq 1 && "$IO_B" -eq 1 ]] && echo 1 || echo 0)"
  io_cleanup

  # 5. unlabeled (neither micro nor standard/complex) → non-micro, so b is
  #    required; d is skipped by the tier rule (same ordering as the full run).
  run_io "" "$NO_MARKER"
  IO_B="$(grep -c '❌ \[b\]' "$IO_LOG" || true)"
  io_report 'unlabeled issue → 1 failure (b; d skipped by tier)' \
    "$([[ "$IO_FAILURES" -eq 1 && "$IO_B" -eq 1 ]] && echo 1 || echo 0)"
  io_cleanup
  unset IO_LOG IO_FAILURES IO_SKIPS IO_REMEDY IO_LISTCAUSE IO_B 2>/dev/null || true


  if [[ "$selffail" -gt 0 ]]; then
    echo "❌ SELF-TEST FAILED ($selffail assertion(s))." >&2
    exit 2
  fi
  echo "✅ SELF-TEST PASS — parse_issue_ref matches a POSITIONAL reference context only (bare #N, owner/repo#N, full URL, pull-URL exclusion; #1012); parse_trace_ref shares that context and covers the artifact-only traceability form; pr_is_artifact_only gates the fallback over docs/ + instruction-layer Markdown + .github/CODEOWNERS and fails closed on any code path; resolve_issue_ref prefers closure."
  exit 0
fi

# ── #792 issue-only preflight (no PR required) ──────────────────────────────
# Evaluates ONLY the checks that need no PR: (b) the scoping-comment marker and
# (d)'s file-independent Wiring branch. Tier exemptions are identical to the full
# run, and the verdict text names the gate's own producing skills. Checks (a),
# (c) and (e) read a PR body / commits / diff that does not exist pre-PR, so
# they are skipped with a named reason and remain enforced at merge time.
#
# This is what lets 01-preflight.md detect a missing artifact in seconds instead
# of after a completed review loop + PR — where the retro artifact invalidates
# the reviewed SHA, so the whole gate cost is paid twice (#745 / PR #778).
if [[ "$ISSUE_ONLY" == "1" ]]; then
  ISSUE_REF="$(resolve_issue_only_ref "$ISSUE_TARGET")"
  IO_ISSUE="${ISSUE_REF##*#}"
  IO_REPO="${ISSUE_REF%#*}"
  IO_REPO="${IO_REPO:-$GH_REPO}"
  echo "Resolving linked issue $ISSUE_REF (labels/comments from repos/$IO_REPO/issues/$IO_ISSUE)..." >&2
  LABELS="$(fetch_json "issues/$IO_ISSUE/labels" '.[].name' 1 "$IO_REPO")"
  # The 0x1e record separator is what lets has_scoping_marker examine EACH
  # comment instead of only the thread's first line. See its rationale block.
  # The separator is IN-BAND, so the body is stripped of any 0x1e first —
  # otherwise a comment containing that byte could fabricate a record boundary
  # and make its own later mention look like an artifact. No comment in this
  # repo contains one, but the delimiter must not be forgeable from the data.
  SCOPING_COMMENT="$(fetch_json "issues/$IO_ISSUE/comments" '.[].body | gsub("\u001e"; "") + "\u001e"' 1 "$IO_REPO")"
  PR_BODY=""; COMMIT_MSGS=""; FILES=""; FILES_EXPECTED=""
  run_checks || true
  summarize
  exit
fi

# ── Live run ────────────────────────────────────────────────────────────────
PR_BODY="$(fetch_json "pulls/$PR_NUMBER" '.body // ""')"

# Files fetched as "status<TAB>filename<TAB>previous_filename" — check e needs
# the status to count only added/modified test files as evidence; checks d/e
# derive plain names; check (a)'s artifact-only gate needs the old path to judge
# renames. Fetched BEFORE the issue resolution: check (a)'s artifact-only fallback
# needs the file list to decide whether a non-closing keyword is acceptable.
FILES="$(fetch_json "pulls/$PR_NUMBER/files" '.[] | "\(.status)\t\(.filename)\t\(.previous_filename // "")"' 1)"
# Authoritative file count for this PR. files_rows demands the validated
# DISTINCT-new-path count EQUAL this, which is what makes a forged or
# truncated list unable to read as complete (and so unable to look
# artifact-only). Distinct paths, not rows: .changed_files counts paths while
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
  # 0x1e separator per comment — has_scoping_marker scans every record. The
  # body is stripped of any 0x1e first, so the delimiter is not forgeable from
  # comment text (see the rationale at the issue-only site above).
  SCOPING_COMMENT="$(fetch_json "issues/$LIVE_ISSUE/comments" '.[].body | gsub("\u001e"; "") + "\u001e"' 1 "$LIVE_ISSUE_REPO")"
fi
COMMIT_MSGS="$(fetch_json "pulls/$PR_NUMBER/commits" '.[].commit.message' 1)"

run_checks || true
summarize
