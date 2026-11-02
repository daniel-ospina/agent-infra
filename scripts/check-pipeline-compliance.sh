#!/usr/bin/env bash
# check-pipeline-compliance.sh — deterministic (no-LLM) CI gate: verifies a PR
# followed the agent pipeline before merge.
#
# The gate checks process evidence, not code quality (that is the code-review
# skill's job; lint/typecheck/tests are separate CI). For a PR it checks, in
# order:
#
#   a. LINKED ISSUE      — PR body references an issue, either with a closing
#                          keyword (Fixes #N / Closes #N / Resolves #N, plus
#                          owner/repo#N or https://github.com/owner/repo/issues/N
#                          for cross-repo issues) or with a NON-closing
#                          traceability keyword (Refs / Part of / Advances /
#                          Tracks / Relates to). Either form must BEGIN A LINE,
#                          optionally after a Markdown line-leading prefix —
#                          bullet, ordered-list marker, blockquote, ATX heading
#                          or task-list checkbox (compound included) — and/or an
#                          emphasis/bold/backtick marker. A mid-sentence
#                          mention is not a reference (#1012).
#                          For cross-repo refs the
#                          labels (tier) and scoping comments (checks b–e) are
#                          fetched from the issue's OWN repo, not the PR's.
#                          The traceability form is accepted for ANY diff
#                          (#1630). Rationale: the gate's job is that a PR is
#                          TRACEABLE to an issue, and requiring a CLOSING
#                          keyword is the wrong test for whether a PR is scoped
#                          to an issue — every closing keyword auto-closes, so
#                          a PR implementing only PART of an issue would have
#                          to LIE (`Closes #N` closes an issue it does not
#                          resolve) or fail the gate. The closing form always
#                          wins when both are present.
#   b. SCOPING COMMENT   — linked issue has a comment with the
#                          `<!-- issue-scoping:` marker (posted by the
#                          issue-scoping skill)
#   c. CODE-REVIEW EVID  — a HEAD-BOUND code-review record must exist for THIS
#                          PR at its CURRENT head (#1825). Two artifacts can
#                          carry it, and the order is fixed (#1224):
#                          1. the RECORD FILE, written and owned by
#                             record-review.sh, which the PR cannot edit:
#                             ~/.pi/agent/reviews/<owner>-<repo>-<PR>.json
#                                 → {pr, head_sha, verdict, repo, reviewed_at}
#                          2. only when no record covers this head, the marker
#                             line a record-review.sh run APPENDS to the PR body
#                             (or a commit message):
#                             review recorded: reviews/<PR>.json verdict=<v> @
#                               <40-hex head sha>[ diff=<64hex>] (owner/repo)
#                               [ sig=<64hex>]
#                          Every field is checked against the live PR: the PR
#                          number, the repo, and the recorded sha == the PR's
#                          current head. A bare PHRASE no longer satisfies this
#                          check — that keyword match was defeated by typing one
#                          of six words into a commit message, with no review
#                          behind it (measured on PR #1822, #1825).
#                          The #513 binding rejects a verdict=clean-micro marker
#                          on a non-micro issue. #1356 adds the parallel
#                          clean-low binding: a verdict=clean-low marker is
#                          accepted ONLY when the PR's whole diff is in the
#                          Low content-shape class, read from the producer's
#                          OWN definition (record-review.sh::clean_low_*,
#                          SOURCED — never restated here).
#                          ⛔ SOURCE ORDER (#1224): the head-bound RECORD FILE
#                          ~/.pi/agent/reviews/<owner>-<repo>-<PR>.json is read
#                          FIRST, and the body/commit marker is the FALLBACK. The
#                          body is one `gh pr edit` away from any lane — an
#                          unrelated typo fix destroyed the attestation on
#                          agent-infra#1209 and premise-labs#3788 — while the
#                          record cannot be edited by the PR at all. Every (c)
#                          line PRINTS which source answered, so a green proved by
#                          the immutable artifact is distinguishable from one
#                          proved by a mutable field. A record whose head_sha is
#                          NOT the head being merged is always refused, naming
#                          both shas: a record certifies exactly one revision.
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
# The PR's CURRENT head sha (pulls .head.sha), set by the live fetch. Check (c)
# binds the record marker's `@ <sha>` to it (#1825), so a marker recorded at an
# earlier revision stops counting the moment the head moves. Empty = the read
# failed, and (c) then fails CLOSED with a message naming the unread head rather
# than accepting any marker it finds.
PR_HEAD=""

# ── The artifact-only CLASS: ONE table, both artifacts RENDERED from it ──────
# Declared HERE — above `usage()` — because the early CLI parse calls `usage`
# long before the evidence-patterns block below; declaring it further down left
# the rendered description unbound under `set -u` on every bad-argument path.
#
# Each row is `<human name>|<path regex fragment>`. ARTIFACT_CLASS_RE (what the
# gate MATCHES) and ARTIFACT_CLASS_DESC (what the user is TOLD) are BOTH rendered
# from this table, so the #1409 defect — one token added to the matcher and four
# prose restatements left stale, two of them user-facing — is impossible by
# construction rather than guarded against.
#
# That rendering IS the seam, and it is why the guards this replaced were
# DELETED rather than sharpened. The previous design scanned the DESCRIPTION for
# path-shaped tokens that were not members; eight falsification rounds each
# closed one spelling and opened another (`CODEOWNERSS`, `, or scripts/**`,
# `pyproject.toml;`, `.github/CODEOWNERS*`, `i.e.`, `AGENTS.md*`), because a
# whitespace tokenizer cannot soundly tell a path from a prose word. Rendering
# removes the thing being scanned. Do NOT reintroduce a scanner — add a row.
ARTIFACT_CLASS_MEMBERS=(
  'docs/|docs/'
  'AGENTS.md|AGENTS\.md$'
  'skills/**/*.md|skills/.*\.md$'
  'templates/**/*.md|templates/.*\.md$'
  '.github/CODEOWNERS|\.github/CODEOWNERS$'
)
# NO trailing `$` on this frame: it would distribute over the group, turning the
# `docs/` PREFIX member into the literal `docs/$` and killing it for every real
# path pull requests actually return. A falsification caught exactly that, and
# the suite went 12 assertions red. Each fragment carries its own anchor where
# one is wanted; the frame contributes only `^(` and `)`.
# Refuse an empty table loudly. On bash 3.2 an empty array aborts under `set -u`,
# but bash >= 4.4 (what CI runs) expands it and renders `^()`, which matches
# EVERY path — the class would then claim a code-only diff is artifact-only.
# A silent fail-open is the one outcome this must never have.
if [[ "${#ARTIFACT_CLASS_MEMBERS[@]}" -eq 0 ]]; then
  echo "❌ ARTIFACT_CLASS_MEMBERS is empty — the artifact-only class would match EVERYTHING. Refusing to start." >&2
  exit 2
fi
ARTIFACT_CLASS_RE="^($(printf '%s\n' "${ARTIFACT_CLASS_MEMBERS[@]}" | cut -d'|' -f2- | paste -sd'|' -))"
# The description is a PURE JOIN of the member names — no prose frame. A frame is
# decoration that CANNOT be validated: it lets a row claim a name by sitting on
# any boundary-delimited span of the sentence (`OWNERS` inside `.github/CODEOWNERS`,
# `Markdown (AGENTS.md` inside the parenthetical), and each spelling needs its own
# heuristic. Ten falsification rounds each closed one spelling and opened another,
# and two of the guards written along the way introduced P0s of their own. Joining
# the names removes the thing being scanned, so there is nothing left to validate.
# The information the old `instruction-layer Markdown` phrase carried — WHY those
# members qualify — belongs in the surrounding help text, which is not the class.
ARTIFACT_CLASS_DESC="$(printf '%s\n' "${ARTIFACT_CLASS_MEMBERS[@]}" | cut -d'|' -f1 | paste -sd, - | sed 's/,/, /g')"

usage() {
  cat >&2 <<EOF
Usage:
  bash scripts/check-pipeline-compliance.sh <PR_NUMBER>
  PR_NUMBER=123 GH_REPO=owner/repo bash scripts/check-pipeline-compliance.sh

  #792 pre-PR mode — issue-side artifacts only (b + d-via-Wiring):
  bash scripts/check-pipeline-compliance.sh --issue-only <N|owner/repo#N>
  PIPELINE_COMPLIANCE_ISSUE_ONLY=1 PIPELINE_COMPLIANCE_ISSUE=<N|owner/repo#N> \\
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
  An issue reference — a closing keyword ("Fixes #N" / "Closes #N" /
  "Resolves #N", or owner/repo#N / a full issue URL) or a NON-closing
  traceability keyword (Refs / Part of / Advances / Tracks / Relates to #N) —
  must BEGIN A LINE, optionally preceded by a Markdown line-leading prefix — a
  bullet, ordered-list marker, blockquote, ATX heading or task-list checkbox
  (compound/nested prefixes included) — and/or an emphasis/bold/backtick
  marker. A mid-sentence mention does NOT count, because it can auto-close an
  issue on merge (#1012).
  The traceability form is accepted for ANY diff (#1630) — including a diff
  that is entirely an artifact ($ARTIFACT_CLASS_DESC) — and closure is NOT
  implied: only a closing keyword auto-closes the issue on merge. Requiring a
  closing keyword is the wrong test for whether a PR is scoped to an issue: a
  PR implementing only PART of one would have to lie (every closing keyword
  closes the issue it names) or fail the gate.

Check (c) scope (#1825):
  The ONLY accepted evidence is a record-review.sh RECORD MARKER on its own
  line — in the PR body or a commit message — bound to this PR:
    review recorded: reviews/<PR>.json verdict=<clean|clean-micro|clean-low> @
      <the PR's CURRENT head sha> (<owner/repo>)
  A phrase ('code-review', 'reviewer', '[review]', 'VGATE',
  'review-enforcer', 'review recorded' on its own) is NOT evidence: it names no
  review, no PR and no revision, so it was satisfiable by typing. A marker
  recorded at an older head does not count either — a record certifies exactly
  one revision.
EOF
}

# ── Marker-probe mode ───────────────────────────────────────────────────────
# PIPELINE_COMPLIANCE_MARKER_PROBE=1 reads ONE scoping-comment body on stdin and
# exits 0/1 on `has_scoping_marker`, doing nothing else. It exists so that a
# SECOND producer of the same question does not grow a second copy of the
# position contract: `scripts/revalidate-required-check-on-issue-comment.sh`
# must decide "is this comment a scoping artifact?" in order to know whether the
# linked issue's state has changed at all, and a hand-rolled grep there would
# drift from this file exactly the way check (b) once did (#991). One parser,
# one contract, two callers.
#
# Deliberately NOT a general "call any function" seam: it takes no function
# name, so it cannot be used to reach a check or a verdict. It answers one
# boolean question and exits.
#
# ⛔ THE PROBE MUST NOT INHERIT AN EARLY-EXIT MODE, so `PROBE_MODE` is computed
# here and the SKIP override below is made conditional on it. Measured before
# that guard existed: `PIPELINE_COMPLIANCE_SKIP=1 PIPELINE_COMPLIANCE_MARKER_PROBE=1`
# exited 0 for the body `no marker here` — i.e. the probe answered "this comment
# IS a scoping artifact" about text with no marker, because the emergency
# override's `exit 0` was reached first. Any probe caller would then re-trigger
# the required check on every comment.
#
# EXIT CODES: `has_scoping_marker` answers 0 and 1 only, and the probe DISPATCH
# adds no third value — but the process can still exit 2 from the usage guards
# ABOVE this block (`GH_REPO` not owner/repo, a malformed `PIPELINE_COMPLIANCE_ISSUE_ONLY`),
# so "the probe never exits 2" would be false about the process. Measured:
# `PIPELINE_COMPLIANCE_MARKER_PROBE=1 GH_REPO=not-a-repo` → 2. A caller must
# therefore treat EVERY non-0/1 as a tooling fault (which is what the shipped
# caller does, and why this distinction matters: a later caller reading `2)` as
# "no marker" would be fail-open).
PROBE_MODE="${PIPELINE_COMPLIANCE_MARKER_PROBE:-0}"

# ── Emergency override ──────────────────────────────────────────────────────
if [[ "${PIPELINE_COMPLIANCE_SKIP:-0}" == "1" && "$PROBE_MODE" != "1" ]]; then
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
elif [[ -z "$PR_NUMBER" && "${PIPELINE_COMPLIANCE_SELF_TEST:-0}" != "1" && "${PROBE_MODE:-0}" != "1" ]]; then
  echo "❌ No PR number given." >&2
  usage
  exit 2
elif [[ ! "$PR_NUMBER" =~ ^[0-9]+$ && "${PIPELINE_COMPLIANCE_SELF_TEST:-0}" != "1" && "${PROBE_MODE:-0}" != "1" ]]; then
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
# The probe answers a question about TEXT and needs no repo at all, so it must
# never fail on an unresolvable remote: probe mode is deliberately repo-FREE and
# never depends on the remote auto-detect above (the gate itself is sanctioned by
# name under #1129/#2332, so a local checkout is not blocked from running it).
# An earlier revision of this comment blamed the #1484 guard for a block it does
# not impose — measured 2026-10-31: probe mode answers 0/1 with `GH_REPO` unset,
# from both the hub and a linked worktree.
if [[ -z "$GH_REPO" && "${PROBE_MODE:-0}" != "1" ]]; then
  echo "❌ Could not determine GH_REPO. Set GH_REPO=owner/repo or run from a repo with a github.com origin." >&2
  exit 2
fi
if [[ -n "$GH_REPO" && ! "$GH_REPO" =~ ^[^/]+/[^/]+$ ]]; then
  echo "❌ GH_REPO must be owner/repo, got: '$GH_REPO'." >&2
  exit 2
fi

if [[ "$DRY_RUN" != "1" && "${PIPELINE_COMPLIANCE_SELF_TEST:-0}" != "1" && "${PROBE_MODE:-0}" != "1" ]]; then
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
# The CROSS-SCRIPT CONTRACT is the keyword CLASS and its BOUNDARY, not the
# position rule: REFCTX, CLOSING_KW and CLOSING_KW_BOUNDARY are byte-identical
# to record-review.sh's copies (pinned mechanically by record-review.test.sh
# §8.13), while record-review's #513 tier guard ALSO scans with the
# BOUNDARY-ANCHORED CLOSING_KW (CLOSING_KW_BOUNDARY + the class, NO REFCTX) —
# GitHub auto-closes a mid-sentence ref, so the tier guard must bind it even
# though check (a) ignores it, and the boundary keeps the class from matching
# INSIDE ordinary English words ("prefix", "discloses", "unresolved").
REFCTX='^[[:space:]]*(([-*+]|[0-9]+[.)])[[:space:]]+|#{1,6}[[:space:]]+|>[[:space:]]*)*(\[[ xX]\][[:space:]]+)*[*_`]{0,3}[[:space:]]*'

# Closing-keyword class (check a's default) and the NON-closing traceability
# class (check a's other accepted form, for ANY diff since #1630). \b anchors
# the TRACE keywords so a
# substring cannot masquerade as one ("prefs #42" must not read as
# "refs #42"). CLOSING_KW stays byte-identical to
# record-review.sh::closing_issue_refs (a documented cross-script contract);
# the positional REFCTX prefix is applied by BOTH scripts by default, so the
# POSITIONAL composed pattern is identical. The tier guard's GitHub-parity scan
# is the one place the composition differs: it composes CLOSING_KW_BOUNDARY +
# CLOSING_KW with NO REFCTX (see the REFCTX comment above) — the CLASS and the
# BOUNDARY stay byte-identical, the positional wrapper is applied per scan. Both
# suites pin the COMPOSED form, and record-review.test.sh §8.13 pins the three
# constant lines byte-for-byte across the scripts (nothing asserted that
# equality before).
CLOSING_KW='(fix(es|ed)?|close(s|d)?|resolve(s|d)?)'

# The GitHub-parity keyword BOUNDARY (#1336) — the position wrapper composed in
# front of CLOSING_KW by BOTH mid-sentence scans (this file's all_close_refs and
# record-review.sh's #513 tier guard). It REPLACES the former `\b`, which is a
# WORD boundary and therefore does NOT fire after `_` — `_` is a word character
# — so `_Closes #N_` was invisible to the hazard scan while check (a) resolved
# it (REFCTX tolerates the emphasis) and GitHub CLOSES it. The scan and the
# admission bar disagreed, and the shape could never become a hazard: a PR body
# wrapping an unintended closing keyword in underscores closed an issue with the
# gate green (#1178/#1271 class, fail-open).
#
# The class is MEASURED against GitHub, not guessed (scratch repo
# `ai-gate-semantics-test` PR #13, body compared to GraphQL
# `closingIssuesReferences`; GitHub renders the body and matches with a word
# boundary):
#   `_Closes #6_`     → CLOSES   (opening `_` starts emphasis; ref inside it)
#   `__Closes #7__`   → CLOSES
#   `**Closes #8**`   → CLOSES   (`\b` already caught the `*` forms)
#   `foo_closes #11`  → IGNORED  (`_` is not an emphasis opener mid-word, so
#                                 `\b`-like parity REQUIRES a word boundary)
#   `_Closes_ #14`    → IGNORED  (a CLOSING marker between keyword and ref is
#                                 NOT stripped, so that shape never closes)
#   `**Closes** #15`  → IGNORED
# So the boundary admits an emphasis OPENING run (`[*_]{0,3}`) ONLY when the run
# itself starts at a word boundary (line start or a non-word char), AND admits
# it after a letter nowhere. `[^[:alnum:]_]` (not `[^[:alnum:]]`) is what keeps
# `foo_closes #N` from being invented as a hazard — GitHub does not close it, so
# flagging it would be a FALSE block, the exact trap `\b` was chosen to avoid.
# (A CLOSING emphasis marker between the keyword and the ref needs no handling:
# GitHub ignores `_Closes_ #14`, so it is not a gap.)
CLOSING_KW_BOUNDARY='(^|[^[:alnum:]_])[*_]{0,3}'
TRACE_KW='\b(ref(s|erences?)?|part[[:space:]]+of|advance(s|d)?|track(s|ed)?|relates?[[:space:]]+to)'

# Evidence patterns for checks (c) and (e) and the #513 clean-micro binding —
# the single source of truth, shared by the live checks and the SELF_TEST
# fixtures (so the regression test exercises the PRODUCTION path, not a copy).
#
# #1825 — CHECK (c)'S EVIDENCE IS A RECORD, NOT A KEYWORD. Until this change the
# matcher was a substring alternation over the PR body and the commit messages
# (`code-review|reviewer|[review]|VGATE|review recorded|review-enforcer`), so a
# PR merged with no reviewer behind it as long as SOMEONE typed one of those
# words — the fastest path to green was typing. MEASURED on PR #1822: the body
# was byte-identical across two runs at the same head and the verdict flipped
# from ❌ to ✅ when one commit message gained `review recorded: code-review
# dispatch marker…`. Nothing bound the phrase to a review, a PR, or a revision.
#
# The replacement is the ONLY artifact the reviewer's own tool writes
# (scripts/record-review.sh, the producer): its marker line, with every field
# bound to the LIVE PR — the PR number it names, the repo it claims, and the
# recorded head sha, which must EQUAL the PR's current head. A stale marker
# therefore stops counting the moment the head moves (the same rule
# merge-one.sh applies when it verifies the signed marker, and the same reason
# ai-review-gate is head-bound). The producer is the single source of truth for
# the SHAPE: REVIEW_RECORD_MARKER_RE mirrors its `MARKER=` line, and the
# self-test pins that shape against the producer's own text where the producer
# is present.
#
# WHAT THIS IS NOT: a proof that a human or a sub-agent read the diff. Every
# session authenticates as one GitHub account, so no such proof is available to
# a deterministic gate (record-review.sh's header states the same boundary).
# What it removes is the SILENT, cheapest path: a word with nothing behind it.
# Producing this line requires the record tool to have minted a record at this
# head — which for `verdict=clean` demands a named, verified review artifact.
REVIEW_RECORD_MARKER_RE='^review recorded: reviews/([0-9]+)\.json verdict=(clean|clean-micro|clean-low) @ ([0-9a-f]{40})( diff=[0-9a-f]{64})? \(([A-Za-z0-9._-]+/[A-Za-z0-9._-]+)\)( sig=[0-9a-f]{64})?$'
TEST_EVIDENCE_RE='tests[[:space:]]+green|[0-9]+[[:space:]]+passed|[0-9]+/[0-9]+|VGATE[[:space:]]+PASS|test[[:space:]]+suite|pytest|npm[[:space:]]+test|vitest'
CLEAN_MICRO_MARKER_RE='verdict=clean-micro @ [0-9a-f]{40}'
# #1356 — the clean-low marker shape. Same precision rule as clean-micro: the
# record-review.sh marker (verdict=… @ <40-hex sha>), never bare prose that
# merely mentions it. The marker may carry `diff=<64hex>` and more after the
# sha, so this anchors only the PREFIX it must have.
CLEAN_LOW_MARKER_RE='verdict=clean-low @ [0-9a-f]{40}'

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
# raced pipeline misreported the artifact class / read as "marker absent"),
# while checks (b), (c), (d) and (e) were fail-closed false BLOCKS.
#
# WHO CONVERTED WHAT: #716 (`0542c6d`, follow-ups `4230ffc`, `25a51e7`) already
# moved all eight sites to here-strings on `main`, so THIS change is the pin,
# not the conversion — it hoists the patterns above so the regression vectors
# exercise the production matchers, and adds the large-input controls. Every
# RED measurement quoted in this file (20/25 at 66 KB, 30/30 at 256 KB and
# 1 MB) is against the PRE-#716 idiom, not against this PR's diff.
# ── #1825: check (c)'s matcher — see the REVIEW_RECORD_MARKER_RE rationale ──
# has_review_record <text> <pr-number> <owner/repo> <head-sha>
#   True iff <text> carries at least one WHOLE-LINE record-review.sh marker
#   whose PR number, repo and recorded head ALL bind to this PR's live identity
#   and current head (#1825). Fails closed on any unbound or partial match: a
#   missing PR number, repo or head is never "close enough".
#
#   Whole-line, not substring: record-review.sh APPENDS the marker as its own
#   line, and a marker embedded mid-sentence inside prose is exactly the
#   quote-in-a-description shape the #513 blind spot was fixed for. A PR body
#   that QUOTES the shape in a paragraph therefore does not satisfy (c); the
#   remedy is to record the review, which appends the real line.
#
#   ⛔ THE VERDICT IS TAKEN FROM THE LINE THAT MATCHED — never from the whole
#   text (#1224 review finding: "the answering source's verdict is not the
#   verdict of the source that matched"). The #513/#1356 verdict predicates are
#   shape greps (`verdict=clean-micro @ [0-9a-f]{40}`, ANY 40-hex, NOT this
#   head), and they used to run over the ENTIRE field — so ONE stale marker
#   anywhere in it (an earlier head, another repo, an agent QUOTING the shape)
#   pinned the verdict for this head. That was tolerable while the field was the
#   PR body, which its author can edit; it is not tolerable once the field is the
#   append-only comment stream, where nobody can remove the stale line. So the
#   scan selects the MARKER LINE, and only that line's verdict is read — see
#   review_marker_verdict below.
#
#   Sets REVIEW_RECORD_MATCHED_LINE / REVIEW_RECORD_MATCHED_VERDICT on success.
#   Several bound markers can coexist at ONE head (the producer APPENDS and never
#   removes), so the STRONGEST verdict wins: re-recording `clean` therefore
#   supersedes a stale `clean-micro`/`clean-low` line, which is what makes the
#   (c) refusal's own remedy actually able to clear the state.
has_review_record() {
  local text="$1" pr="$2" repo="$3" head="$4" line want_repo got_repo v rank best_rank=0
  REVIEW_RECORD_MATCHED_LINE=""; REVIEW_RECORD_MATCHED_VERDICT=""
  [[ -n "$pr" && -n "$repo" && -n "$head" ]] || return 1
  want_repo="$(printf '%s' "$repo" | tr 'A-Z' 'a-z')"
  while IFS= read -r line; do
    [[ "$line" =~ $REVIEW_RECORD_MARKER_RE ]] || continue
    [[ "${BASH_REMATCH[1]}" == "$pr" ]] || continue
    [[ "${BASH_REMATCH[3]}" == "$head" ]] || continue
    got_repo="$(printf '%s' "${BASH_REMATCH[5]}" | tr 'A-Z' 'a-z')"
    [[ "$got_repo" == "$want_repo" ]] || continue
    v="$(review_marker_verdict "$line")"
    rank="$(review_verdict_rank "$v")"
    if [ "$rank" -gt "$best_rank" ]; then
      best_rank="$rank"
      REVIEW_RECORD_MATCHED_LINE="$line"
      REVIEW_RECORD_MATCHED_VERDICT="$v"
    fi
  done <<<"$text"
  [ -n "$REVIEW_RECORD_MATCHED_LINE" ]
}
has_test_evidence() { grep -qiE "$TEST_EVIDENCE_RE" <<<"$1"; }
has_clean_micro_marker() { grep -qE "$CLEAN_MICRO_MARKER_RE" <<<"$1"; }
has_clean_low_marker() { grep -qE "$CLEAN_LOW_MARKER_RE" <<<"$1"; }

# review_marker_verdict <bound marker line> — the verdict OF THE LINE THAT
# MATCHED, through the same #513/#1356 SHAPE predicates the whole-text scan used
# (so both predicates stay the single definition of "what a micro/low marker
# looks like"), applied to ONE line.
review_marker_verdict() {
  if has_clean_micro_marker "$1"; then printf 'clean-micro'
  elif has_clean_low_marker "$1"; then printf 'clean-low'
  else printf 'clean'; fi
}

# review_verdict_rank <verdict> — clean 3 > clean-low 2 > clean-micro 1.
# Ordering, not preference: the producer APPENDS markers and never removes one,
# so a re-record leaves the previous line in place. Taking the STRONGEST bound
# verdict is what lets "re-record clean" clear a stale clean-micro, which is the
# only remedy that exists for a line in an append-only comment stream.
review_verdict_rank() {
  case "$1" in
    clean)       printf '3' ;;
    clean-low)   printf '2' ;;
    clean-micro) printf '1' ;;
    *)           printf '0' ;;
  esac
}

# ── #1224 review findings: THE COMMENT ARM'S TRANSPORT AND ITS ADMISSION ─────
#
# Two defects, both in the arm the diff itself calls "the copy that TRAVELS" —
# i.e. the only arm that can answer on the required `pipeline-compliance` check
# (a clean `ubuntu-latest` runner whose $HOME has no `~/.pi/agent/reviews`).
#
# (1) THE SEPARATOR WAS INSIDE THE LINE THE MATCHER ANCHORS ON. The fetch
#     terminates EVERY comment body with a raw 0x1e (`+ "\u001e"`), because the
#     in-band separator is what proves comment boundaries. `has_review_record`
#     scans line-wise and anchors the marker at `$` — and `record-review.sh`
#     posts the marker as the comment's WHOLE body, with no trailing newline. So
#     the line the gate read for the producer's own evidence comment was
#     `review recorded: … sig=<64hex><0x1e>`, which `$` cannot match: the arm was
#     INERT for the exact artifact the producer writes, and the red #1224 measures
#     (agent-infra#1209, premise-labs#3788) stayed red on the only merge-blocking
#     check while `pass 1224d` reported green — because its fixture handed over a
#     BARE marker and bypassed the transport entirely. That is the #633 class
#     (model the TRANSPORT, not just the URL), one file over.
#     FIX: split the blob on the separator here (`read -d $'\036'`), the same way
#     `has_scoping_marker` splits it with `awk -v RS='\036'`, and make the fixture
#     build its input through the PRODUCTION shape (p1224_comment below), so a
#     future change to the separator reds the vector instead of silently
#     disabling the arm.
#
# (2) THE ARM ADMITTED ANY COMMENTer'S TEXT. `PR_COMMENTS` was `.[].body` for
#     EVERY comment with no author filter, and `REVIEW_RECORD_MARKER_RE`'s
#     `sig=` group is optional and never verified on that arm. On a PUBLIC repo
#     (this one) any GitHub account can comment, so one typed line satisfied the
#     repo's only required status check with no review behind it — the gate
#     defeated by a party with NO write access, which IS new reach: the PR body
#     it replaced can only be edited by someone who already has write access.
#     FIX: the fetch now carries each comment's `author_association` in-band, and
#     the arm admits a comment only when
#       (a) GitHub attests its author is OWNER / MEMBER / COLLABORATOR — the
#           byte-identical admission rule the #1224 decision comment fixes as the
#           shared contract (`PR_EVIDENCE_COMMENTS_JQ`), so this reader admits
#           the same evidence the other readers do; and
#       (b) the marker is the comment's WHOLE body (that is the producer's
#           artifact; a marker quoted inside a longer comment is a MENTION, the
#           same distinction check (b) makes with "mentioned, not artifact"); and
#       (c) its `sig=` verifies under the gate key WHEN one is resolvable here —
#           the HMAC over the marker text up to ` sig=`, exactly as
#           record-review.sh signs it and merge-one.sh::verify_any_marker checks
#           it. When no key exists on the box the arm falls back to the
#           association bound alone and SAYS SO in the (c) line
#           (`source=comment … no gate key on this box`), because the required
#           check's workflow passes no `AI_REVIEW_GATE_KEY` and this repo has no
#           such secret: requiring a verifiable sig there would make the arm
#           inert again, which is defect (1) all over. The association is
#           GitHub-asserted provenance (a commenter cannot choose it), so with
#           no key the forger set is exactly the set that can already edit the
#           body — the boundary does not move — and a key, where present, tightens
#           it to the key holder.
#
# The separator is IN-BAND, so both fields are stripped of 0x1e/0x1f before the
# frame is built: a comment containing the delimiter must not be able to
# fabricate a record boundary (the same rule the scoping fetch states).
REVIEW_COMMENT_TRUSTED_ASSOC_RE='^(OWNER|MEMBER|COLLABORATOR)$'
# The ONLY place the comments fetch expression is written. The SELF_TEST builds
# its fixtures from the same two bytes, so the vector and production cannot
# drift (the defect (1) above).
REVIEW_COMMENTS_ASSOC_SEP=$'\037'
REVIEW_COMMENTS_REC_SEP=$'\036'
REVIEW_COMMENTS_JQ='.[] | "\(.author_association)\u001f\(.body | gsub("[\u001e\u001f]"; ""))" + "\u001e"'

# review_marker_sig_ok <marker-line> <key> — the producer's marker HMAC, verified.
# Signs the marker text UP TO (excluding) ` sig=`, exactly as
# record-review.sh::MARKER does and merge-one.sh::verify_any_marker verifies. A
# marker with no `sig=`, a non-hex `sig=` or a mismatch is NOT ok — fail closed.
review_marker_sig_ok() {
  local line="$1" key="$2" txt sig exp
  [ -n "$key" ] || return 1
  [[ "$line" =~ ^(.*)\ sig=([0-9a-f]{64})$ ]] || return 1
  txt="${BASH_REMATCH[1]}"
  sig="${BASH_REMATCH[2]}"
  exp="$(printf '%s' "$txt" | command openssl dgst -sha256 -hmac "$key" 2>/dev/null | command awk '{print $NF}' || true)"
  [ -n "$exp" ] && [ "$exp" = "$sig" ]
}

# has_comment_review_record <comment-blob> <pr> <owner/repo> <head>
#   True iff the PR's comment stream carries the producer's marker for THIS PR at
#   THIS head, from an admitted author. Sets:
#     REVIEW_COMMENT_MATCHED_LINE    the marker line that matched
#     REVIEW_COMMENT_MATCHED_VERDICT the verdict OF THAT LINE (never of the blob)
#     REVIEW_COMMENT_AUTH            sig | association (WHY the author is trusted)
#     REVIEW_COMMENT_REFUSED         why a marker-SHAPED comment was refused, for
#                                    the refusal text ("" when none was)
#
#   <comment-blob> is `REVIEW_COMMENTS_JQ`'s output verbatim: one record per
#   comment, `<author_association>\x1f<body>\x1e`.
has_comment_review_record() {
  local blob="$1" pr="$2" repo="$3" head="$4"
  local rec assoc body want_repo got_repo key best_rank=0 rank v auth
  REVIEW_COMMENT_MATCHED_LINE=""; REVIEW_COMMENT_MATCHED_VERDICT=""
  REVIEW_COMMENT_AUTH=""; REVIEW_COMMENT_REFUSED=""
  [[ -n "$pr" && -n "$repo" && -n "$head" ]] || return 1
  [ -n "$blob" ] || return 1
  want_repo="$(printf '%s' "$repo" | tr 'A-Z' 'a-z')"
  key="$(review_gate_key)"
  while IFS= read -r -d "$REVIEW_COMMENTS_REC_SEP" rec; do
    [ -n "$rec" ] || continue
    case "$rec" in
      *"$REVIEW_COMMENTS_ASSOC_SEP"*)
        assoc="${rec%%"$REVIEW_COMMENTS_ASSOC_SEP"*}"
        body="${rec#*"$REVIEW_COMMENTS_ASSOC_SEP"}" ;;
      *)
        # Not the production frame: refuse rather than guess an author.
        REVIEW_COMMENT_REFUSED="a comment record carried no author_association field, so its author could not be admitted"
        continue ;;
    esac
    # The marker is the comment's WHOLE body (trailing whitespace tolerated: a
    # client that adds a newline still posts the same artifact).
    while [[ "$body" == *[[:space:]] ]]; do body="${body%?}"; done
    [[ "$body" =~ $REVIEW_RECORD_MARKER_RE ]] || continue
    [[ "${BASH_REMATCH[1]}" == "$pr" ]] || continue
    [[ "${BASH_REMATCH[3]}" == "$head" ]] || continue
    got_repo="$(printf '%s' "${BASH_REMATCH[5]}" | tr 'A-Z' 'a-z')"
    [[ "$got_repo" == "$want_repo" ]] || continue
    # (a) ADMISSION BY AUTHOR.
    if ! [[ "$assoc" =~ $REVIEW_COMMENT_TRUSTED_ASSOC_RE ]]; then
      REVIEW_COMMENT_REFUSED="its author_association is '$assoc', not OWNER/MEMBER/COLLABORATOR — on a public repo any account can comment, so an unattested commenter is not evidence"
      continue
    fi
    # (c) ADMISSION BY SIGNATURE, wherever a key exists to check it against.
    if [ -n "$key" ]; then
      if review_marker_sig_ok "$body" "$key"; then
        auth="sig"
      else
        REVIEW_COMMENT_REFUSED="its sig= does not verify under this box's gate key (missing, re-keyed, or edited after minting), so nothing binds that comment to the review gate"
        continue
      fi
    else
      auth="association"
    fi
    v="$(review_marker_verdict "$body")"
    rank="$(review_verdict_rank "$v")"
    if [ "$rank" -gt "$best_rank" ]; then
      best_rank="$rank"
      REVIEW_COMMENT_MATCHED_LINE="$body"
      REVIEW_COMMENT_MATCHED_VERDICT="$v"
      REVIEW_COMMENT_AUTH="$auth"
    fi
  done <<<"$blob"
  [ -n "$REVIEW_COMMENT_MATCHED_LINE" ]
}

# ── #1224: THREE SOURCES, IN ONE FIXED ORDER — RECORD → COMMENT → BODY ──────
#
# THE DEFECT THIS REMOVES FROM THE TRUST PATH. `record-review.sh` mints THREE
# artifacts for one review and they are NOT interchangeable:
#   1. the record FILE (`~/.pi/agent/reviews/<owner>-<repo>-<PR>.json`), carrying
#      `head_sha`, `verdict` and now a `sig` — head-bound, PR-ineditable, and
#      PER BOX;
#   2. a signed MARKER LINE appended to the PR BODY;
#   3. a PR COMMENT carrying that same signed marker line.
# The body is one `gh pr edit` away from anybody — an unrelated typo fix, a
# corrected claim, the closing keyword `pipeline-compliance` demands — while the
# file cannot be edited by the PR at all. Measured 2026-09-18: agent-infra#1209 and
# premise-labs#3788 both went RED on a genuinely reviewed head because the body had
# been improved after the review. So the RECORD is read first.
#
# ⛔ WHY THE COMMENT IS BETWEEN THEM, AND NOT AN OPTIONAL EXTRA. The record store
# is `$HOME/.pi/agent/reviews` — the required `pipeline-compliance` check runs on a
# clean `ubuntu-latest` runner, where that directory does not exist, so the record
# arm can NEVER answer there and the measured red would stay red on the only check
# that blocks a merge. The comment is the copy that TRAVELS; it is also a WIDER
# write field than the body (on a public repo any account can comment, where a
# body edit needs write access), so it carries its own admission rule —
# author_association ∈ OWNER/MEMBER/COLLABORATOR, plus the marker `sig` wherever a
# gate key is resolvable on the box (the CI runner passes none, and a sig-only arm
# there would be inert again). See has_comment_review_record.
#
# ⛔ NEVER RE-ORDERED, and never silently: which source answered is PRINTED on
# every (c) arm (`source=record (…)` / `source=comment (…)` / `source=body (…)`),
# so a reader can tell a green proved by an immutable artifact from one proved by a
# mutable field — and a red that reports what each arm actually read.
#
# ⛔ THIS MAKES THE BODY AUTHORITATIVE NOWHERE. The fallback keeps every existing
# binding (PR number, repo, head, #513 tier, #1356 shape) so no in-flight PR
# loses its only surviving copy, and the tier bindings are applied to the
# verdict OF THE SOURCE THAT ANSWERED. An in-flight PR whose only record is the
# body still passes, and still prints `source=body`.
#
# ⛔ AND A PRE-#1224 RECORD IS NO LONGER EVIDENCE. The record arm requires a `sig`
# over the four fields the gate reads (see below), so every record minted before
# that requirement — including every record already sitting on a box — is refused
# and the gate falls through to the comment, then the body. That is a behaviour
# change, not an accident: an unsigned private file nobody can audit is exactly
# the artifact that was unacceptable. Re-running the producer mints a signed one.
#
# ⛔ THE HEAD COMPARISON IS THE WHOLE POINT. A record bound to a different
# revision is the STALE class: accepting it would certify an unreviewed head, so
# it is refused BY NAME, with both shas printed.
#
# Fail closed everywhere: an absent file, an unreadable field, a `verdict`
# outside the accepted set, or an empty head are all NON-evidence — the arms
# below refuse rather than degrade to "close enough".
REVIEW_STORE_VERDICTS_RE='^(clean|clean-micro|clean-low)$'

# ── #1224 review finding 3: THE RECORD MUST BE AUTHENTICATED ─────────────────
#
# A record FILE is a PRIVATE, per-box artifact. Unlike the body marker it leaves
# NO trace on the PR — no body line, no comment, nothing `gh` or a human reviewer
# can audit. Before this guard, the gate accepted any file at the store path whose
# `verdict`/`repo`/`head_sha` fields read correctly, so
#   printf '{"pr":1,"head_sha":"<head>","verdict":"clean","repo":"o/r"}' > ~/.pi/agent/reviews/o-r-1.json
# satisfied check (c) with nothing to see afterwards. That is BELOW the bar the
# producer already sets for the artifact that DOES travel: `record-review.sh`
# signs its marker with HMAC-SHA256 under AI_REVIEW_GATE_KEY precisely so a
# `sig=<64 zeros>` shape cannot be adopted (#784/#2055/#2872). An unauthenticated
# primary source that nobody can observe is the worse half of the same problem.
#
# So a record is EVIDENCE only when its `sig` verifies under the gate key. The
# producer writes it (`record_sig_for`); the canonical text is
#   review-record:v1:<pr>:<head_sha>:<verdict>:<repo>
# — a FIXED-ORDER field list, NOT the record's on-disk bytes. That is deliberate:
# RFC 8785 (JSON Canonicalization Scheme) exists because "cryptographic
# operations like hashing and signing need the data to be expressed in an
# invariant format"; the record file is written by a `printf` whose optional
# fields (diff_sha256, merge_base, mint, evidence) reorder the byte layout for
# different mints of the SAME identity, so signing the serialization would make
# a legitimate record unverifiable for a reason unrelated to its content. The
# fields are exactly the four the gate acts on, so the signature covers the
# verdict and the revision it certifies — nothing the gate reads is outside it.
#
# FAIL CLOSED on every arm: no `sig` field, a `sig` that is not 64 hex, no gate
# key on this box, and a `sig` that does not verify are all NON-evidence. The
# body/comment fallback below is what keeps a PR from being stranded by that.
REVIEW_RECORD_SIG_RE='^[0-9a-f]{64}$'

# review_gate_key — the HMAC key, env first then the producer's key file. Same
# resolution order as record-review.sh, so a gate and a producer on one box
# agree by construction. Prints "" when unconfigured (the caller fails closed).
review_gate_key() {
  local k="${AI_REVIEW_GATE_KEY:-}"
  if [ -z "$k" ] && [ -f "${HOME:-/nonexistent}/.pi/agent/.ai-review-gate-key" ]; then
    k="$(cat "${HOME:-/nonexistent}/.pi/agent/.ai-review-gate-key" 2>/dev/null || true)"
  fi
  printf '%s' "$k" | tr -d '[:space:]'
}

# review_record_sig_text <pr> <head> <verdict> <repo> — the canonical signed text.
# ONE definition, here, and the SELF_TEST pins it against the producer's copy so a
# divergence reds the suite instead of silently refusing every record.
review_record_sig_text() { printf 'review-record:v1:%s:%s:%s:%s' "$1" "$2" "$3" "$4"; }

# review_store_candidates <pr> <owner/repo> — the record paths, qualified first.
# The producer writes the repo-QUALIFIED name and keeps a legacy `<pr>.json`
# until a qualified record for the same repo migrates it (#426), so both are
# read (a box mid-migration must not read as "no evidence"); the qualified name
# wins because it is the one the producer maintains. The repo spelling is
# lowercased for the file name only — `has_review_record` already compares repo
# case-insensitively, and GitHub repo names are case-insensitive.
review_store_candidates() {
  local pr="$1" repo="$2" slug
  [ -n "$pr" ] && [ -n "$repo" ] || return 0
  slug="$(printf '%s' "$repo" | tr 'A-Z' 'a-z')"
  printf '%s\n' \
    "${HOME:-/nonexistent}/.pi/agent/reviews/${slug%/*}-${slug#*/}-$pr.json" \
    "${HOME:-/nonexistent}/.pi/agent/reviews/${repo%/*}-${repo#*/}-$pr.json" \
    "${HOME:-/nonexistent}/.pi/agent/reviews/$pr.json"
}

# review_record_field <file> <field> — the record's raw string value, "" if absent.
# Same idiom the record's other consumers use (merge-one.sh::record_at_head,
# admin-merge.sh's update-safety read): a flat `"key":"value"` scan, so a
# record whose fields are in a different ORDER still reads. ⛔ It reads NOTHING
# from a record re-serialised with spaces around the colon (`"head_sha": "…"`)
# — that yields empty, which every caller treats as NON-evidence: a fail-closed
# miss, never a pass on a field we could not read. The producer writes compact
# JSON, and this refuses rather than guesses if that ever changes.
review_record_field() {
  local f="$1" key="$2"
  sed -n 's/.*"'"$key"'":"\([^"]*\)".*/\1/p' "$f" 2>/dev/null | command head -1
}

# review_record_eval <file> <pr> <owner/repo> <head> — prints the record's
# verdict and returns 0 iff <file> is EVIDENCE for this PR at this head.
#
# ONE implementation BOTH accepts and explains (the reviewer's finding 4): on a
# refusal it prints nothing and sets REVIEW_RECORD_REJECT_REASON to the one fact
# that refused the file, so the refusal text can never assert a cause the check
# never evaluated. Before this, the gate printed "record absent" for a record
# that was present-but-unusable — unprovability it had not verified.
#
# ⛔ THE HEAD BINDING IS THE WHOLE POINT, and it is load-bearing: with the
# comparison neutered a record for an OLDER head is accepted and check (c)
# certifies an unreviewed revision (the SELF_TEST's 1224b mutation flips exactly
# that arm). The signature binding (below it) is the second load-bearing arm —
# the 1224e mutation flips that one.
review_record_eval() {
  local f="$1" pr="$2" repo="$3" head="$4"
  local verdict rec_repo sha want_repo sig expect key
  REVIEW_RECORD_REJECT_REASON=""
  if [ ! -f "$f" ]; then
    REVIEW_RECORD_REJECT_REASON="no file"
    return 1
  fi
  verdict="$(review_record_field "$f" verdict)"
  if ! [[ "$verdict" =~ $REVIEW_STORE_VERDICTS_RE ]]; then
    REVIEW_RECORD_REJECT_REASON="its verdict is '${verdict:-<absent>}', not one of clean|clean-micro|clean-low"
    return 1
  fi
  # A record that NAMES another repo is not this PR's, however its number reads —
  # PR numbers collide across repos, and the legacy `<pr>.json` candidate is
  # shared by all of them. An absent `repo` field is the legacy shape (#426) and
  # is accepted on the head binding alone.
  rec_repo="$(review_record_field "$f" repo)"
  if [ -n "$rec_repo" ]; then
    want_repo="$(printf '%s' "$repo" | tr 'A-Z' 'a-z')"
    if [ "$(printf '%s' "$rec_repo" | tr 'A-Z' 'a-z')" != "$want_repo" ]; then
      REVIEW_RECORD_REJECT_REASON="it names repo '$rec_repo', not '$repo' (PR numbers collide across repos)"
      return 1
    fi
  fi
  sha="$(review_record_field "$f" head_sha)"
  # ⛔ `if [ … ]; then` on its own line, NOT `[ … ] || continue`: the SELF_TEST's
  # 1224b mutation neutralises THIS test by name, and a one-liner guard would be
  # silently skipped by a regex that no longer matches (a mutation that reports
  # itself blind is a mutation that proves nothing).
  if [ "$sha" != "$head" ]; then
    REVIEW_RECORD_REJECT_REASON="its head_sha is '${sha:-<absent>}', not this head"
    return 1
  fi
  # THE AUTHENTICITY ARM (#1224 finding 3). See the REVIEW_RECORD_SIG_RE block.
  #
  # ⛔ The signed text covers the record's OWN `head_sha`, not the live head: the
  # signature attests "this file says <pr, head, verdict, repo>", and the guard
  # directly above attests "that head is the one merging". Making the canonical
  # text use the LIVE head would fold both assertions into one — the suite could
  # then not tell which arm refused, and the head binding would go untested
  # behind a signature that fails for the same reason (measured: the 1224b
  # mutation read as "not caught" until this was split).
  sig="$(review_record_field "$f" sig)"
  if [ -z "$sig" ]; then
    REVIEW_RECORD_REJECT_REASON="it carries no sig= field, so nothing binds its content to the review gate (every pre-#1224 record, and any hand-written one)"
    return 1
  fi
  if ! [[ "$sig" =~ $REVIEW_RECORD_SIG_RE ]]; then
    REVIEW_RECORD_REJECT_REASON="its sig= field is not a sha256 hex digest"
    return 1
  fi
  key="$(review_gate_key)"
  if [ -z "$key" ]; then
    REVIEW_RECORD_REJECT_REASON="its signature cannot be VERIFIED — no AI_REVIEW_GATE_KEY in the environment or at ~/.pi/agent/.ai-review-gate-key on this box, so the record is unauthenticated rather than merely unproven"
    return 1
  fi
  expect="$(printf '%s' "$(review_record_sig_text "$pr" "$sha" "$verdict" "$rec_repo")" \
    | command openssl dgst -sha256 -hmac "$key" 2>/dev/null | command awk '{print $NF}' || true)"
  if [ "$expect" != "$sig" ]; then
    REVIEW_RECORD_REJECT_REASON="its sig= does not verify under this box's gate key — written under a different key, edited after minting, or minted for a different revision"
    return 1
  fi
  printf '%s' "$verdict"
}

# review_record_at_head <pr> <owner/repo> <head> — prints "<path> <verdict>" and
# returns 0 iff a RECORD for this PR is EVIDENCE at exactly this head.
review_record_at_head() {
  local pr="$1" repo="$2" head="$3" f verdict
  [ -n "$pr" ] && [ -n "$repo" ] && [ -n "$head" ] || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    [ -f "$f" ] || continue
    if verdict="$(review_record_eval "$f" "$pr" "$repo" "$head")"; then
      printf '%s %s\n' "$f" "$verdict"
      return 0
    fi
  done < <(review_store_candidates "$pr" "$repo")
  return 1
}

# resolve_review_evidence <evid-text> <pr> <owner/repo> <head> [<comment-text>]
#   Returns 0 iff a HEAD-BOUND source was found, and sets:
#     REVIEW_EVIDENCE_SOURCE          record | comment | body
#     REVIEW_EVIDENCE_VERDICT         clean | clean-micro | clean-low
#     REVIEW_EVIDENCE_WHERE           the record path, "PR comments", or
#                                     "PR body/commit messages"
#     REVIEW_EVIDENCE_STALE_PATH/SHA  a record present at ANOTHER head (refused,
#                                     reported) — "" when there is none
#     REVIEW_EVIDENCE_RECORD_PRESENT  the first record file seen for this PR,
#                                     even when unusable (so a refusal can say
#                                     "a file exists but is not evidence")
#     REVIEW_EVIDENCE_RECORD_REASON   WHY that file is not evidence, produced by
#                                     the same review_record_eval that refused it
#     REVIEW_EVIDENCE_COMMENT_AUTH    sig | association — WHY the comment arm
#                                     trusted the comment it read ("" when the
#                                     comment arm did not answer)
#     REVIEW_EVIDENCE_COMMENT_REFUSED why a marker-SHAPED comment was refused
#                                     (unauthorised author, unverifiable sig) —
#                                     so a refusal can report what it evaluated
#   Order is RECORD → COMMENT → BODY.
#
#   ⛔ WHY THE COMMENT ARM EXISTS (#1224 review finding 2, the P1). The record
#   store is `$HOME/.pi/agent/reviews` — PER BOX. The required `pipeline-compliance`
#   check runs on a clean `ubuntu-latest` runner, where nothing materializes that
#   directory, so the record arm can never answer there and #1224's measured red
#   (agent-infra#1209, premise-labs#3788) would stay RED on the only check that
#   blocks a merge. Issue #1224 records option (a) — gate reads the record file —
#   as the recommendation with option (b) "post the attestation as a COMMENT… a
#   body edit cannot wipe one" as its documented fallback; this is (a) as the
#   PRIMARY source plus (b) as the source that TRAVELS, which is what reaching
#   the reported population requires. The comment is append-only in practice, so
#   the `gh pr edit` that wiped #1209 cannot reach it, and unlike the record file
#   it is PUBLIC — it leaves an audit trail in the same place the body marker did.
#
#   ⛔ AND IT IS NOT "THE SAME AS THE BODY ARM". It is a WIDER field — on a public
#   repo any GitHub account can comment, where the body needs write access — so it
#   carries its OWN admission rule (author_association ∈ OWNER/MEMBER/COLLABORATOR,
#   plus the marker sig wherever a key exists to verify it).
#   `has_comment_review_record` states what that rule closes and why it is not
#   simply "require a sig": the required check's workflow passes no gate key, so
#   a sig-only arm would be INERT there — the defect it was meant to fix.
#
#   ⛔ AND THE VERDICT IS THE MATCHED LINE'S, on every arm — see
#   review_marker_verdict. Reading it from the whole field let one stale marker
#   (any 40-hex, any head) set the tier binding for THIS head, which on an
#   append-only comment stream could not be undone.
#
#   The body arm keeps the pre-#1224 matcher (`has_review_record`) with its legacy
#   unsigned tolerance, so an in-flight PR is not stranded: nothing about what a
#   BODY marker must say changed here — only which artifact is consulted first.
resolve_review_evidence() {
  local text="$1" pr="$2" repo="$3" head="$4" comments="${5:-}" hit path verdict f sha
  REVIEW_EVIDENCE_SOURCE=""; REVIEW_EVIDENCE_VERDICT=""; REVIEW_EVIDENCE_WHERE=""
  REVIEW_EVIDENCE_STALE_PATH=""; REVIEW_EVIDENCE_STALE_SHA=""; REVIEW_EVIDENCE_RECORD_PRESENT=""
  REVIEW_EVIDENCE_RECORD_REASON=""; REVIEW_EVIDENCE_COMMENT_AUTH=""; REVIEW_EVIDENCE_COMMENT_REFUSED=""
  [ -n "$pr" ] && [ -n "$repo" ] && [ -n "$head" ] || return 1
  # 1. THE IMMUTABLE SOURCE.
  if hit="$(review_record_at_head "$pr" "$repo" "$head")"; then
    path="${hit% *}"; verdict="${hit##* }"
    REVIEW_EVIDENCE_SOURCE="record"
    REVIEW_EVIDENCE_VERDICT="$verdict"
    REVIEW_EVIDENCE_WHERE="$path"
    REVIEW_EVIDENCE_RECORD_PRESENT="$path"
    return 0
  fi
  # Remember what was there for the refusal text: a record at another head, a
  # record that is not evidence, and no record at all are THREE different facts,
  # and only one of them is fixed by re-recording. The reason comes from the same
  # review_record_eval that refused the file, so it cannot assert a cause the
  # check never evaluated.
  while IFS= read -r f; do
    [ -n "$f" ] && [ -f "$f" ] || continue
    if [ -z "$REVIEW_EVIDENCE_RECORD_PRESENT" ]; then
      REVIEW_EVIDENCE_RECORD_PRESENT="$f"
      review_record_eval "$f" "$pr" "$repo" "$head" >/dev/null || true
      REVIEW_EVIDENCE_RECORD_REASON="$REVIEW_RECORD_REJECT_REASON"
    fi
    sha="$(review_record_field "$f" head_sha)"
    if [ -n "$sha" ] && [ "$sha" != "$head" ]; then
      REVIEW_EVIDENCE_STALE_PATH="$f"; REVIEW_EVIDENCE_STALE_SHA="$sha"
      break
    fi
  done < <(review_store_candidates "$pr" "$repo")
  # 2. THE SOURCE THAT TRAVELS — the PR comment the producer posts beside the body
  #    marker. NOT the same matcher: comment bodies arrive in the fetch's frame
  #    (`<association>\x1f<body>\x1e`) and are admitted by AUTHOR and by SIGNATURE,
  #    because a comment — unlike the body it backs up — can be written by any
  #    account on a public repo. The bindings (PR, repo, head) and the verdict
  #    rule (the matched LINE, never the blob) are identical to the other arms;
  #    see has_comment_review_record for the two defects this closes.
  if has_comment_review_record "${comments:-}" "$pr" "$repo" "$head"; then
    REVIEW_EVIDENCE_SOURCE="comment"
    REVIEW_EVIDENCE_VERDICT="$REVIEW_COMMENT_MATCHED_VERDICT"
    REVIEW_EVIDENCE_COMMENT_AUTH="$REVIEW_COMMENT_AUTH"
    case "$REVIEW_EVIDENCE_COMMENT_AUTH" in
      sig) REVIEW_EVIDENCE_WHERE="PR comments, sig verified" ;;
      *)   REVIEW_EVIDENCE_WHERE="PR comments, from a trusted author_association (no gate key on this box to verify sig=)" ;;
    esac
    return 0
  fi
  REVIEW_EVIDENCE_COMMENT_REFUSED="${REVIEW_COMMENT_REFUSED:-}"
  # 3. THE LAST-RESORT FALLBACK — the PR body / commit messages, unchanged bindings.
  if has_review_record "$text" "$pr" "$repo" "$head"; then
    REVIEW_EVIDENCE_SOURCE="body"
    REVIEW_EVIDENCE_WHERE="PR body/commit messages"
    REVIEW_EVIDENCE_VERDICT="$REVIEW_RECORD_MATCHED_VERDICT"
    return 0
  fi
  return 1
}

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
  # mid-sentence mention cannot satisfy the traceability form either.
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
# A non-closing reference asserts "this PR advances #N", not "this PR completes
# #N": it satisfies check (a) for ANY diff (#1630), and it never closes the
# issue on merge. Call it only from resolve_issue_ref, AFTER the closing form
# has been tried — the closing form must always win there.
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
# safe error, and refusing is the direction this gate exists for. A body that
# quotes the keyword form — in a fence OR in inline code — is therefore refused
# when the number is not the intended one: name it without the keyword, or drop
# the number. Inline code is NOT suppressed anywhere in the blocking path; the
# advisory in close_word_notes explains the one consequence that would otherwise
# be silent.
#
# The keyword class is anchored by CLOSING_KW_BOUNDARY: CLOSING_KW's class is a
# SUFFIX of ordinary English words ("prefix", "discloses", "unresolved"), and
# `_` opens emphasis before a keyword but is a WORD character, so a plain `\b`
# invented hazards out of prose while MISSING `_Closes #N_` entirely (the
# fail-open #1336 fixes). The boundary's measured GitHub parity is documented at
# its definition — in particular `foo_closes #N` is NOT a hazard, so an
# unanchored scan that invents one is the same false-refusal trap
# record-review.sh's tier guard documents.

# WHAT IS MODELLED, AND WHY IT IS ONLY THIS (adversarial review, cycle 1). Four
# fixes across three rounds all failed the same way: each tried to MODELF text —
# first fences, then inline-code subtraction — and each attempt produced
# FAIL-OPENS, hiding the very closure this gate exists to catch. So the blocking
# rule now SUPPRESSES NOTHING:
#
#   H1 (BLOCKING) — every reference the body names with a closing keyword must
#   resolve to the issue the author meant. No subtraction, no inert set.
#   Suppressing a suppression can only make the scan MORE conservative, so H1
#   cannot fail open by construction; it can only false-block, and a false block
#   is visible, is one edit to clear, and reports its remedy.
#
#   H2 (ADVISORY, NON-blocking) — the intended keyword also appearing inside
#   inline code. Its harm is an issue that stays open: visible, and requiring no
#   gate to notice. Gating it produced a false block whose own message asserted
#   the opposite of the truth, so it advises instead.
#
# The three fail-opens this deletes, every one reproduced by the reviewer:
#   P1 — the span regex paired ANY two backticks, so a line holding two inline
#        spans made a live unintended closure look inert.
#   P2 — the inert set held NUMBERS, so one inert mention of N disarmed the
#        report for every live mention of N.
#   P3 — references were compared as bare numbers, so "Closes other/repo#N" plus
#        a bare "closes #N" collapsed into one value and the unintended closure
#        of the LOCAL issue went unreported. References are QUALIFIED now.
# And the false block it removes:
#   P4 — a body with a live intended keyword AND a backticked quotation of it was
#        refused, with a message claiming the link would not be created.
#
# What is deliberately NOT modelled, so the omission is not mistaken for an
# oversight: fences, HTML comments and raw `<code>` HTML are all scanned as LIVE.
# Whether GitHub skips them could not be established, and guessing is what
# produced the fail-opens above, so the gate refuses rather than waves through.

# normalize_ref <raw-ref> — a closing reference as a QUALIFIED owner/repo#N ref,
# lowercased so case differences cannot manufacture a hazard. Handles the bare,
# owner/repo and full-URL forms parse_issue_ref accepts; a bare #N belongs to the
# repo the gate runs against.
normalize_ref() {
  local ref rest
  # LOWERCASE FIRST. The case pattern below matches the URL's scheme and host, and
  # matching those case-sensitively while parse_issue_ref accepts any case made the
  # gate refuse a body's OWN intended issue whenever the host was capitalised — a
  # false block, found independently by both cycle-2 reviewers.
  ref="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
  case "$ref" in
    https://github.com/*/issues/*)
      rest="${ref#https://github.com/}"
      # SHORTEST suffix match (`%/issues/*`, NOT `%%`), so a repository actually
      # named "issues" keeps its name: owner/issues/issues/173 → owner/issues#173.
      # The greedy form ate the repo name and mismatched the intended ref — the
      # second false block the cycle-2 reviewers reproduced.
      ref="${rest%/issues/*}#${rest##*/}" ;;
    \#*) ref="${GH_REPO}${ref}" ;;
  esac
  printf '%s\n' "$ref" | tr '[:upper:]' '[:lower:]'
}

# all_close_refs <text> — every reference <text> names with a closing keyword,
# one per line, deduped: the set of issues this body WILL close on merge.
all_close_refs() {
  printf '%s\n' "$1" \
    | grep -ioE "${CLOSING_KW_BOUNDARY}${CLOSING_KW}[[:space:]]*:?[[:space:]]*(#[0-9]+|https://github.com/[^/[:space:],;)]+/[^/[:space:],;)]+/issues/[0-9]+|[[:alnum:]_.-]+/[[:alnum:]_.-]+#[0-9]+)" \
    | sed -E -e 's/^[^[:alpha:]]+//' -e 's/^[[:alpha:]]+[[:space:]]*:?[[:space:]]*//' \
    | while read -r raw; do [[ -n "$raw" ]] && normalize_ref "$raw"; done \
    | sort -u
}

# code_span_close_refs <text> — the issue numbers whose closing keyword sits
# INSIDE inline code (backticks). ADVISORY ONLY (see close_word_notes): this set
# is NEVER subtracted from the blocking scan. It is a naive span matcher — it
# pairs any two backticks, so a line holding two spans can mis-pair them — and
# that is tolerable only because a wrong answer here changes a NOTE, never a
# verdict. Do not reintroduce it into the blocking path.
code_span_close_refs() {
  printf '%s\n' "$1" \
    | grep -ioE '`[^`]*'"${CLOSING_KW}"'[^`]*(#[0-9]+|/[0-9]+)[^`]*`' \
    | grep -oE '(#[0-9]+|/[0-9]+)' | grep -oE '[0-9]+' | sort -n -u
}

# scan_close_word_hazards <text> <intended-ref> — H1 only: the BLOCKING hazard
# text, or empty when clean. Every reference named with a closing keyword must be
# the intended one; nothing is suppressed (see the comment above normalize_ref).
# <intended-ref> is the QUALIFIED ref resolve_issue_ref returned.
scan_close_word_hazards() {
  local text="$1" intended="$2" out="" ref want
  want="$(printf '%s' "$intended" | tr '[:upper:]' '[:lower:]')"
  for ref in $(all_close_refs "$text"); do
    [[ "$ref" == "$want" ]] && continue
    out+="      ⚠️  H1 unintended close: the body names ${ref} with a closing keyword, so GitHub will CLOSE it on merge. Its parser reads the words and not the sentence — a negation is not understood, so a sentence saying the work does NOT close it IS that instruction."$'\n'
  done
  printf '%s' "$out"
}

# close_word_notes <text> <intended-ref> — the ADVISORY text for H2, NEVER a
# failure. Hedged deliberately: the span matcher behind it can be wrong in either
# direction, so it states the consequence of the SHAPE rather than asserting what
# GitHub will do (the unhedged version asserted the opposite of the truth on a
# body whose intended keyword was also live — review cycle 1, P4).
close_word_notes() {
  local text="$1" intended="$2" out="" n want_num
  want_num="${intended##*#}"
  for n in $(code_span_close_refs "$text"); do
    [[ "$n" == "$want_num" ]] || continue
    out+="      ℹ️  note (NOT a failure): the closing keyword for #$n also appears inside inline code. GitHub skips code spans, so if that is the ONLY occurrence, the link this description intends will not be created. Write it in plain text to be sure."$'\n'
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

# ── Marker-probe early exit ─────────────────────────────────────────────────
# Runs immediately after the definition it reads and BEFORE any check, fetch or
# gh call, so the probe cannot be turned into a partial run of the gate.
if [[ "${PROBE_MODE:-0}" == "1" ]]; then
  # ⛔ STRIP THE IN-BAND RECORD SEPARATOR FIRST. The live fetch sites do exactly
  # this (`gsub("\u001e"; "")`) because the delimiter must not be forgeable from
  # the data — a body carrying a literal 0x1e could otherwise fabricate a record
  # boundary and make its own later mention look like an artifact. Measured
  # without it: `printf 'intro\n\036<!-- issue-scoping: forged -->\n'` answered 0
  # (artifact) where the real check (b) answers 1. The two callers must share the
  # SANITIZATION as well as the awk, or "one parser, one contract" is only half
  # true.
  probe_payload="$(tr -d '\036'; printf '\036')"
  if has_scoping_marker "$probe_payload"; then exit 0; else exit 1; fi
fi

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
      # be accepted, or a legitimate diff list is wrongly rejected.
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
# the class declared once as ARTIFACT_CLASS_RE / ARTIFACT_CLASS_DESC above.
# This comment deliberately does NOT re-list the class (#1611).
# `files` is the "<status><TAB><filename><TAB><old>" list from the pulls/files
# fetch. Fails CLOSED on anything it cannot prove: since #1630 it no longer
# GATES check (a) — the traceability keyword is accepted for any diff — but it
# still selects how check (a)'s PASS line reads, and it is this gate's single
# statement of the artifact class, so it must never answer `true` for a diff it
# cannot prove is entirely artifacts.
#
# THE CLASS IS A POSITIVE ALLOWLIST (#786), not a negative "no executable
# extension" rule: docs/ (any file — the #720 carve-out), instruction-layer
# Markdown that ships governance/skill prose but no runtime work,
# .github/CODEOWNERS (review-routing config with no executable logic — the
# #786 headline case, PR #674), and nothing else. A negative rule was rejected
# because a new or unlisted file type would enter the class silently — the
# wrong direction for a class that must be provable. A CODE PR (any
# .ts/.js/.mjs/script/workflow path) is simply not on the list. `docs/` is a
# PREFIX (any file under it); the
# other entries are EXACT/pattern paths, so e.g. `.github/workflows/*.yml`,
# `.github/CODEOWNERS.d/x` and `templates/.github/workflows/pipeline-compliance.yml`
# are NOT artifacts. The `templates/` entry is Markdown-only (#1409) for exactly
# that reason: 18 of the 21 tracked files under templates/ are executable
# (workflows, launchd plists, husky hooks, JSON config), so a directory-wide
# entry would have classified a workflow edit as an artifact.
# Four ways to be untrustworthy, all → NOT artifact-only:
#   1. Empty/unreadable list (a broken fetch must never be answered as
#      artifacts).
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
  # the unit GitHub caps at. Counting ROWS would wrongly deny the artifact class
  # to a complete list of >=3000 diff entries with fewer distinct
  # paths (a delete+add pair is two rows for one path).
  count="$(printf '%s\n' "$rows" | LC_ALL=C awk -F '\t' '{ print $2 }' | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  [[ "$count" -lt 3000 ]] || return 1
  # Both ends of every row must be in the artifact class (the new path always,
  # the old path whenever present). One failing row denies the class — this
  # is the anti-vacuous guard: one code path anywhere makes the diff NOT
  # artifact-only.
  paths="$(printf '%s\n' "$rows" | LC_ALL=C awk -F '\t' '{ print $2; if ($3 != "") print $3 }')"
  [[ -n "$paths" ]] || return 1
  # #836 — here-string, never `printf … | grep -q`. This one was the most
  # dangerous site of the family: a raced pipeline INVERTS to "artifact-only"
  # (fail-OPEN), so the classifier answers `true` for a diff that is not one.
  # templates/**/*.md is instruction-layer Markdown in the SAME sense as
  # AGENTS.md and skills/**/*.md (#1409): it ships governance prose, implements
  # no runtime work, and — being the source that materializes into every repo's
  # AGENTS.md — is the file the base⊆AGENTS.md pin FORCES every instruction-layer
  # rule change to touch. Before #1630 the class gated check (a)'s traceability
  # keyword, so leaving templates/ off the allowlist blocked exactly those PRs
  # (#1400 merged only by taking a false close; #1461 sat red 11 days). Since
  # #1630 the class only words the PASS line, and the entry is kept because the
  # class is this gate's one statement of what "artifact" means.
  # The `.md` restriction is load-bearing, not decorative: see the 18/21 note
  # above.
  ! grep -qvE "$ARTIFACT_CLASS_RE" <<<"$paths"
}

# ── #1356 — the Low content-shape CLASS is SOURCED, never redeclared ──────────
# clean-low's class lives in ONE place: scripts/record-review.sh (the producer
# that MINTS the marker, and the guard that refuses to mint it for a diff that
# is not Low-shaped). check (c) must answer the SAME question — "is this diff in
# the Low class?" — so it sources that definition instead of carrying a second
# copy of the class. A copy is a second writer of one contract: the two drift
# silently, and the drift shows up as a marker the producer would have refused
# passing the gate (or a legitimate one being blocked).
#
# WHY SOURCING IS SAFE. record-review.sh has a `[[ "${BASH_SOURCE[0]}" == "$0" ]]`
# guarded main, so a `source` executes its top-level DEFINITIONS only (the
# REFCTX/CLOSING_KW/CLOSING_KW_BOUNDARY constants — byte-identical to this
# script's, a documented cross-script contract pinned by record-review.test.sh
# §8.13 — and the clean_low_* predicates, all declared ABOVE the guard).
# Sourcing therefore runs no main, writes no record, and calls no gh. The
# constants are RESTORED straight after the source: see the note on the restore
# below for why "byte-identical" must not be relied on to make that harmless.
#
# The class admits PROSE and STYLESHEETS only — deliberately narrower than the
# two other content-shape classes in this repo (pr_is_artifact_only above, and
# extensions/verification-gate::isShapeExemptFile). The producer's header
# documents the divergence and why each is a different projection for a
# different gate; #1356's decision is to keep that divergence EXPLICIT and share
# the one class that answers clean-low's question, rather than reconcile three
# classes that were each chosen for a different job.
#
# Resolution is a sibling of THIS script (the repo copy under review — never the
# mutable ~/.pi/agent/scripts copy), so the class the gate enforces is the class
# the PR's own tree declares.
#
# ⚠ THE TRUST LIMIT, STATED AT THE SOURCE (#1356 review round 2). Reading the
# class from the PR's own tree makes that tree a TRUST INPUT: a PR that weakens
# clean_low_path_ok — e.g. `case "$p" in extensions/mine.ts) return 0 ;; esac`
# right here — suppresses the binding for its own path, and the SELF_TEST's real
# arms do NOT catch it (its pass-6 fixture is extensions/example/sample.ts, so a
# whitelist that leaves the fixture refused keeps the suite green). Weakening the
# FIXTURE path instead IS caught (the real-script arm reddens), so only the
# targeted form evades. That is not repairable by enumeration — no fixed canary
# list can cover an arbitrary attacker path — and it is not #1356's defect to
# fix: it is the structural class "the gate's inputs are not trusted, and it is
# graded by a copy the PR controls", whose remedy (a pinned ref, a separate
# checkout, or a checksum-pinned copy) is the OPEN DECISION on #713. What this
# gate DOES do is refuse to let the trust input grow past the class it came for:
# the three parser constants are restored below, so the source contributes
# clean_low_* and nothing else. #713 carries this arm as evidence. Do not
# restate this as "the shape is re-derived from the PR's diff" — that phrasing
# hides the trust input and was a review finding on #1356.
# Captured as ONE `declare -p` blob, NOT three assignments: record-review.test.sh
# §8.13 greps EVERY line matching ^(REFCTX|CLOSING_KW|CLOSING_KW_BOUNDARY)= in
# both files and compares the blocks, so a second assignment line here would
# (correctly) read as a one-sided edit of the cross-script contract. A
# `declare -p` blob is invisible to that grep, and the pin keeps its
# "every matching line" strictness — which is what catches an OVERRIDING
# assignment, the shape this restore defends against.
GATE_PARSER_CONSTS="$(declare -p REFCTX CLOSING_KW CLOSING_KW_BOUNDARY)"
RECORD_REVIEW_SH="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/record-review.sh"
CLEAN_LOW_CLASS_SOURCED="false"
if [[ -f "$RECORD_REVIEW_SH" ]]; then
  # The `if source …; then` form is deliberate: it keeps `set -e` from aborting
  # the WHOLE gate on a corrupted sibling, and leaves CLEAN_LOW_CLASS_SOURCED
  # false so the binding fails closed with the named missing-class message
  # instead of a bare shell error.
  # shellcheck disable=SC1090  # a resolved sibling in this repo, not a literal
  if source "$RECORD_REVIEW_SH"; then
    CLEAN_LOW_CLASS_SOURCED="true"
  else
    echo "⚠️ #1356: could not source the Low content-shape class from $RECORD_REVIEW_SH — a verdict=clean-low marker will be refused (its shape is unverifiable)." >&2
  fi
fi

# ── The source must not REBIND this gate's own parser constants (#1356 r2) ────
# record-review.sh declares REFCTX/CLOSING_KW/CLOSING_KW_BOUNDARY too (§8.13's
# byte-identity contract), and `source` runs AFTER this file's own definitions —
# so without this restore the PRODUCER's values win and this file's are dead
# code. In agent-infra the two are byte-identical (§8.13 pins it), which is
# exactly why the effect is INVISIBLE here and observable in a consumer repo that
# ships the producer without §8.13 (WIRING OPTION 1 copies the two files, not the
# test): a producer from a different revision would silently rebind check (a)'s
# parser and the close-hazard scan from a file the PR controls. Restoring the
# values captured before the `source` keeps the source's contribution to the
# class this gate came for. This is NOT a second declaration of the contract — it
# is this gate's OWN declaration re-asserted over a sibling's, so §8.13 still
# holds the two equal. (`eval` of a `declare -p` blob built from this file's own
# single-quoted literals is the exact round-trip; the values are never untrusted.)
eval "$GATE_PARSER_CONSTS"

# pr_is_clean_low_shaped <files-rows> — true iff the diff is PROVABLY in the Low
# content-shape class, judged by the producer's OWN predicates: its row framing
# (clean_low_rows — which refuses `copied`), its count binding against the PR's
# authoritative .changed_files, its cap, and its per-path class. Fails CLOSED
# whenever the class could not be sourced, the rows are malformed, or the count
# cannot be bound: "could not prove Low" must never read as "Low".
#
# MUTATION ANCHOR (#1356): neutering THIS function to `return 0` must make the
# check (c) binding stop firing on a code-bearing diff — the SELF_TEST's
# mutation vector asserts exactly that, so the shape check is load-bearing and
# not decorative.
pr_is_clean_low_shaped() {
  [[ "$CLEAN_LOW_CLASS_SOURCED" == "true" ]] || return 1
  local rows
  rows="$(clean_low_rows <<<"$1")" || return 1
  clean_low_shape_ok "$rows" "${FILES_EXPECTED:-}" || return 1
  return 0
}

# resolve_issue_ref <pr-body> — check (a)'s resolution, shared with the live
# issue lookup so checks b–e always run against the SAME issue the gate
# reported in (a). The closing keyword wins outright; when there is no closing
# reference a NON-closing traceability keyword resolves (#1630).
# The resolution is deliberately DIFF-AGNOSTIC: the traceability form is
# accepted for ANY diff, code included, because requiring a CLOSING keyword is
# the wrong test for whether a PR is scoped to an issue — every closing keyword
# auto-closes, so a PR implementing only PART of an issue would have to LIE or
# fail. The artifact class no longer gates this; it only classifies check (a)'s
# PASS line (pr_is_artifact_only, called from run_checks).
resolve_issue_ref() {
  local ref
  ref="$(parse_issue_ref "$1")"
  if [[ -z "$ref" ]]; then
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
  local out rc err
  # stderr is captured SEPARATELY, never merged into the same variable as the
  # payload. The old `2>&1` had two harms, and the first one is the boring one:
  #   (i) DATA CORRUPTION — on a SUCCESSFUL call a warning line became the first
  #       line of the value the gate consumed, so a parsed PR_BODY could begin
  #       "Warning: API rate limit is near its secondary threshold" (reproduced
  #       against origin/main).
  #  (ii) the failure message buried the cause: jq's parse error on a NON-JSON
  #       body was printed as the whole story, which on CI is indistinguishable
  #       from a policy violation. (jq runs INSIDE `gh api --jq` on the HTTP
  #       body, so stderr merging was never what produced that message — the
  #       body being non-JSON was. An earlier version of this comment claimed
  #       otherwise; a fresh-context review caught it.)
  # See #1876 for the general form.
  # `mktemp` with an explicit TEMPLATE: bare `mktemp` ignores $TMPDIR on BSD/macOS
  # and always lands in /tmp, so the file escapes the caller's temp root.
  err="$(mktemp "${TMPDIR:-/tmp}/pc-fetch.XXXXXX")" || { echo "❌ [fetch] could not create a temp file for stderr" >&2; exit 2; }
  # `cmd && rc=0 || rc=$?` rather than `cmd; rc=$?`: under `set -o posix` or
  # `shopt -s inherit_errexit` a bare failing assignment exits the shell before
  # rc is captured — no diagnostic, no verdict, and the caller sees gh's status
  # instead of the gate's 2. Same idiom as scripts/admin-merge.sh (#1690).
  if [[ "$paginate" == "1" ]]; then
    out="$(gh api "repos/$repo/$path" --paginate --jq "$expr" 2>"$err")" && rc=0 || rc=$?
  else
    out="$(gh api "repos/$repo/$path" --jq "$expr" 2>"$err")" && rc=0 || rc=$?
  fi
  if (( rc != 0 )); then
    echo "❌ [fetch] gh api failed for repos/$repo/$path (exit $rc)" >&2
    [[ -s "$err" ]] && sed 's/^/   stderr: /' "$err" >&2
    # $out can carry PR/issue-controlled text (page-1 bodies on a failed --paginate),
    # and it is echoed into the same stream as the VERDICT lines — so flatten it to
    # one line: a body containing a newline plus a forged "VERDICT:" must not be
    # able to spoof the log.
    [[ -n "$out" ]] && printf '   stdout: %s\n' "$(printf '%s' "${out:0:400}" | tr '\n' ' ')" >&2
    # FOUR classes, ordered by what the operator must DO, because one message for
    # all of them sent people to the wrong fix (#1690). Order matters and is
    # asserted by the suite: a rate limit must be caught BEFORE 403/404, since
    # GitHub answers a rate limit with 403 as well as 429 and treating that as a
    # permanent access defect is the exact inversion this change exists to fix.
    #   1. transient: rate limit / 429 / 5xx / abuse detection -> re-run.
    #   2. the API did not answer with JSON (proxy/5xx page): jq failed to parse it
    #      and THAT message used to be the whole story.
    #   3. 403/404 with no transient signature: a reference or access defect.
    #   4. anything else: unknown tooling failure.
    # Only $err is classified. $out may contain PR/issue-controlled text — a body
    # that merely QUOTES one of these messages must never select the class.
    # The transient class matches a REFUSAL signature, never a mention. A benign
    # "Warning: API rate limit is near its secondary threshold; continuing" rides
    # along with ordinary failures, and a bare `rate limit` alternative made that
    # warning outrank a real 422 — the same wrong-advice defect (#1690) in the
    # opposite direction. Both genuine refusals contain `exceeded` or `secondary
    # rate limit`; a permanent 403 says "Resource not accessible".
    if grep -qiE 'rate limit exceeded|secondary rate limit|too many requests|abuse detection|HTTP 429|HTTP 5[0-9][0-9]' "$err" 2>/dev/null; then
      echo "   VERDICT: BLOCKED-BY-TOOLING — the API refused on a TRANSIENT condition (rate limit / 5xx)," >&2
      echo "   so the gate could not read the PR. This is NOT a policy failure and NOT a defect in the PR:" >&2
      echo "   wait for the limit window (or the backend) and re-run." >&2
    elif grep -qE 'invalid character|parse error|not valid JSON|Unexpected token' "$err" 2>/dev/null; then
      echo "   VERDICT: BLOCKED-BY-TOOLING — the API did not answer with JSON, so the gate could not read" >&2
      echo "   the PR. jq reported a PARSE error, which is not a policy verdict: a 5xx/rate-limit/proxy page" >&2
      echo "   reads the same as a non-compliant PR otherwise. Re-run; if it persists, the endpoint is down." >&2
    elif grep -qE '(^|[^0-9])(404|403)([^0-9]|$)' "$err" 2>/dev/null; then
      echo "   VERDICT: BLOCKED-BY-TOOLING — the gate could not READ the path above (404/403)." >&2
      echo "   With no rate-limit signature, this is a reference or access defect — NOT transient: check" >&2
      echo "   GH_REPO, PR_NUMBER and the token's access to that repository, then re-run." >&2
    else
      echo "   VERDICT: BLOCKED-BY-TOOLING — the gate could not READ the PR. This is NOT a policy failure," >&2
      echo "   and it must not be reported as one: a gh outage may never masquerade as non-compliance." >&2
      echo "   Check GH_REPO, PR_NUMBER, and gh auth." >&2
    fi
    rm -f "$err"; exit 2
  fi
  # A successful call may still warn on stderr: surface it, never parse it.
  [[ -s "$err" ]] && sed 's/^/   warning (ignored, not parsed): /' "$err" >&2
  rm -f "$err"
  printf '%s' "$out"
}

# ── Core checks ─────────────────────────────────────────────────────────────
# Runs against globals (set by the caller): PR_BODY, LABELS, SCOPING_COMMENT,
# COMMIT_MSGS, FILES. Prints pass/fail per check; returns failure count.

run_checks() {
  local issue_ref="" issue_ref_kind="" issue_number="" issue_repo="" issue_display="" plan_file="" wiring_found="no" close_hazards="" close_notes="" hazard_intended=""
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

  # a. LINKED ISSUE — an issue reference in the PR body; "owner/repo#N" (repo =
  # $GH_REPO for a bare "#N"). resolve_issue_ref is the SINGLE resolution
  # point, shared with the live issue lookup below, so check (a)'s verdict and
  # the issue that b–e actually run against can never drift apart.
  #
  # A non-closing traceability keyword resolves for ANY diff (#1630) — not only
  # for an artifact-only PR. Requiring a CLOSING keyword is the wrong test for
  # whether a PR is scoped to an issue: every closing keyword auto-closes, so a
  # PR implementing only PART of an issue would have to LIE (claim a close it
  # does not perform) or fail the gate. The closing form still always wins when
  # both are present, and only a closing keyword auto-closes on merge.
  # pr_is_artifact_only no longer gates this; it only selects the wording of
  # the PASS line below.
  if [[ "$ISSUE_ONLY" == "1" ]]; then
    # #792 --issue-only: the target issue is an INPUT, not a PR-body parse —
    # pre-PR there is no PR body for check (a) to read. Skipped with a named
    # reason; the full-PR path below is untouched.
    issue_ref="$ISSUE_REF"
    issue_ref_kind="issue-only"
  else
    issue_ref="$(resolve_issue_ref "$PR_BODY")"
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
    # the other half of the question: does the body also close something it never
    # claimed to? See scan_close_word_hazards — the blocking shape is an
    # unintended closure; close_word_notes carries the non-blocking one. Both
    # were live on PR #1271 and the old check passed it.
    #
    # #1630 (P1) — the hazard scan's "intended" ref is only a sound
    # suppression when the body CLOSES it. Pre-#1630 issue_ref was ALWAYS a ref
    # the body closed, so "the body names its own intended ref with a closing
    # keyword" was a reason to stay quiet. A traceability ref is the opposite:
    # a ref the body explicitly does NOT close, so it must match NO close-ref.
    # Passing it would SILENCE a body that says "Part of #N — this does NOT
    # close #N" while GitHub closes #N on merge, turning a blocked PR into a
    # false PASS whose merge performs a closure the author disclaimed. The
    # sentinel cannot equal any close-ref: every ref all_close_refs emits is a
    # normalized ref carrying a '#'.
    #
    # #1630 (P2, disclosed) — a SECOND consequence, and it too is the
    # conservative direction: with nothing suppressed, a traceability body that
    # merely QUOTES a closing keyword in inline code — for its own issue — now
    # hard-fails, where it previously passed with the H2 advisory. That is not a
    # regression but the invariant above all_close_refs finally applying here:
    # inline code is NOT suppressed anywhere in the blocking path.
    hazard_intended="$issue_ref"
    [[ "$issue_ref_kind" == "traceability" ]] && hazard_intended="__no_intended_close__"
    close_hazards="$(scan_close_word_hazards "$PR_BODY" "${hazard_intended:-${GH_REPO}#${issue_number}}")"
    if [[ -n "$close_hazards" ]]; then
      fail a "closing keyword hazard — GitHub acts on the WORDS in the PR body, not on the sentence: this body would close an issue it does not claim to close."
      printf '%s\n' "$close_hazards"
      echo "      Remedy: to say an issue stays open, do NOT write a closing word next to its number — write \"leaves #N open\" or \"#N stays open\". And never wrap a real closing keyword in backticks: GitHub skips code spans, so it closes nothing."
      echo "      Invoke:  commit-workflow — rewrite the PR body, then re-run this gate."
      echo ""
    else
      close_notes="$(close_word_notes "$PR_BODY" "${issue_ref:-${GH_REPO}#${issue_number}}")"
      if [[ -n "$close_notes" ]]; then printf '%s\n' "$close_notes"; fi
      if [[ "$issue_ref_kind" == "closing" ]]; then
        pass a "linked issue $issue_display (closing keyword in PR body)"
      elif pr_is_artifact_only "$FILES"; then
        pass a "linked issue $issue_display (traceability keyword in PR body — artifact-only PR, closure not implied)"
      else
        pass a "linked issue $issue_display (traceability keyword in PR body — PART of $issue_display, closure not implied)"
      fi
    fi
  else
    fail a "no linked issue — PR body must carry an issue reference that BEGINS A LINE (a Markdown line-leading prefix — bullet, ordered-list marker, blockquote, ATX heading, task-list checkbox, compound prefixes included — or an emphasis/bold/backtick marker may precede it; a mid-sentence mention does NOT count, and can auto-close an issue on merge). EITHER a CLOSING keyword (\"Fixes #N\" / \"Closes #N\" / \"Resolves #N\", or owner/repo#N / full issue URL for cross-repo), which auto-closes the issue on merge, OR a NON-closing traceability keyword (\"Refs #N\" / \"Part of #N\" / \"Advances #N\" / \"Tracks #N\" / \"Relates to #N\"), which does not. The traceability form is accepted for ANY diff (#1630) — the artifact-only class ($ARTIFACT_CLASS_DESC) is no longer required for it — because requiring a closing keyword forces a PR that implements only PART of an issue to falsely auto-close it."
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

    # c. CODE-REVIEW EVIDENCE — a head-bound record-review.sh marker for THIS PR.
    EVID_TEXT="$(printf '%s\n%s\n' "$PR_BODY" "$COMMIT_MSGS")"
    if [[ "$ISSUE_ONLY" == "1" ]]; then
      # #792: needs the PR body/commits, which do not exist pre-PR. Skipped
      # with a named reason; the merge-time run still enforces it.
      echo "ℹ️  [c] Skipped: --issue-only mode (needs the PR body/commits — enforced at the required status check)."
    elif [[ -z "$PR_HEAD" ]]; then
      # #1825 — FAIL CLOSED ON AN UNREAD HEAD. The marker is bound to the head,
      # so without one there is nothing to bind it to; accepting the marker on
      # its other fields alone would let a record made at ANY past revision
      # count at the current one, which is the stale-marker fail-open the
      # head binding exists to remove.
      fail c "code-review evidence cannot be graded — the PR's current head sha could not be read, so no record can be BOUND to this revision. Re-run the gate once the API is reachable (the fetch this check needs is pulls/$PR_NUMBER .head.sha)."
      echo "      Missing: a readable PR head sha."
      echo "      Invoke:  re-run this gate — a transient API/permission failure leaves the head unresolved."
    elif resolve_review_evidence "$EVID_TEXT" "$PR_NUMBER" "$GH_REPO" "$PR_HEAD" "${PR_COMMENTS:-}"; then
      # #1224 — WHICH SOURCE ANSWERED, printed on every arm of (c).
      REV_SRC="source=${REVIEW_EVIDENCE_SOURCE} (${REVIEW_EVIDENCE_WHERE})"
      REV_FELLBACK=""
      if [[ "$REVIEW_EVIDENCE_SOURCE" != "record" ]]; then
        if [[ -n "$REVIEW_EVIDENCE_STALE_PATH" ]]; then
          REV_FELLBACK="; the on-disk record ${REVIEW_EVIDENCE_STALE_PATH} is bound to ${REVIEW_EVIDENCE_STALE_SHA} — NOT this head — so it was refused and the ${REVIEW_EVIDENCE_SOURCE} answered"
        elif [[ -n "$REVIEW_EVIDENCE_RECORD_PRESENT" ]]; then
          REV_FELLBACK="; the on-disk record ${REVIEW_EVIDENCE_RECORD_PRESENT} was read and is NOT evidence (${REVIEW_EVIDENCE_RECORD_REASON:-refused}), so the ${REVIEW_EVIDENCE_SOURCE} answered"
        fi
      fi
      # #513 verdict-tier binding (Approach B): clean-micro certifies the
      # MICRO process only (record-review.sh verifies the linked issue's
      # complexity:micro label at mint; micro skips checks b–e, so reaching
      # this branch means the issue is NOT micro). A non-micro PR carrying
      # verdict=clean-micro is a false certification — the verdict is read
      # from the SOURCE THAT ANSWERED (the record's own field when the record
      # answered, the marker LINE that matched otherwise; #1224 moved the
      # source, not the rule). Remediation: record-review.sh APPENDS markers and
      # never removes them, so a stale clean-micro line stays where it is — which
      # is why the scan takes the STRONGEST bound verdict and why re-recording
      # clean DOES clear this state, in the body and in the append-only comment
      # stream alike (before that rule the remedy could not be carried out for a
      # comment at all).
      # Precision (#513 self-review catch): the binding must match the
      # record-review.sh MARKER shape (verdict=… @ <40-hex sha>) — never bare
      # prose mentioning the marker text (this PR's own description tripped
      # the bare-substring grep on the first pipeline-compliance run).
      case "$REVIEW_EVIDENCE_VERDICT" in
        clean-micro) REV_KIND="micro" ;;
        clean-low)   REV_KIND="low" ;;
        *)           REV_KIND="plain" ;;
      esac
      if [[ "$REV_KIND" == "micro" ]]; then
        fail c "clean-micro verdict marker on a NON-micro linked issue (tier $tier) — clean-micro certifies the micro process only; run the code-review skill on the current head and re-record clean (record-review.sh <PR> <head-sha> clean <repo> --evidence <artifact>). The stale \"verdict=clean-micro\" line lives in ${REVIEW_EVIDENCE_WHERE} and cannot be removed from an append-only comment stream, so the STRONGER clean verdict at this head is what supersedes it. [$REV_SRC]"
      elif [[ "$REV_KIND" == "low" ]]; then
        # #1356 clean-low content-shape binding. clean-low certifies that EVERY
        # changed path of the recorded revision is in the Low content-shape
        # class. Unlike clean-micro (a tier exemption), clean-low claims a
        # property of THE DIFF, and this gate can read the diff — so accepting
        # the marker on a code-bearing PR would be a false PASS.
        #
        # THE CLASS IS NOT RESTATED HERE. It is SOURCED from its single
        # definition in the producer, scripts/record-review.sh
        # (CLEAN_LOW_DOCS_RE / clean_low_path_ok / clean_low_rows /
        # clean_low_shape_ok — all defined above its guarded main, so a
        # `source` runs no main). A second matcher here would be a second
        # writer of one contract, and the three content-shape classes in this
        # repo already diverge deliberately (see the producer's header); this
        # binding must not add a fourth. See pr_is_clean_low_shaped below.
        #
        # FAIL CLOSED on every arm: a marker we cannot shape-check (producer
        # absent) is refused, exactly like a marker we can prove wrong.
        if [[ "$CLEAN_LOW_CLASS_SOURCED" != "true" ]]; then
          fail c "clean-low verdict marker, but the Low content-shape class could not be read — record-review.sh is not beside this gate (looked at $RECORD_REVIEW_SH), so the diff's shape is UNVERIFIABLE and the clean-low attestation is refused. Ship record-review.sh alongside scripts/check-pipeline-compliance.sh (both are agent-infra files; templates/.github/workflows/pipeline-compliance.yml's WIRING notes cover copying/fetching it), or re-record with the verdict the diff earns."
        elif pr_is_clean_low_shaped "$FILES"; then
          pass c "code-review record bound to $GH_REPO#$PR_NUMBER at ${PR_HEAD:0:12}… (clean-low verdict; the PR's diff IS Low-shaped) [$REV_SRC$REV_FELLBACK]"
        else
          fail c "clean-low verdict marker on a diff that is NOT Low-shaped — clean-low certifies that EVERY changed path is in the Low content-shape class, defined ONCE by record-review.sh::clean_low_path_ok (sourced, not restated), and this PR's diff is not. Re-record at the current head with the verdict the diff actually earns (record-review.sh <PR> <head-sha> clean <repo> --evidence <artifact> — its own shape guard refuses clean-low here); that stronger verdict supersedes the stale \"verdict=clean-low\" line, which lives in ${REVIEW_EVIDENCE_WHERE}. [$REV_SRC$REV_FELLBACK]"
        fi
      else
        pass c "code-review record bound to $GH_REPO#$PR_NUMBER at ${PR_HEAD:0:12}… [$REV_SRC$REV_FELLBACK]"
      fi
    else
      # #1825 — the remedy NAMES the producer and the head it must bind to, and
      # it deliberately does NOT print a token list: the old message advertised
      # the six accepted phrases, so the fastest path to green was typing one of
      # them (agent-infra#1904's own failure text). A gate that teaches a lane
      # how to pass it without doing the work is how (c) trained lanes to route
      # around the process.
      # #1224 — the refusal names EVERY source it consulted, and distinguishes the
      # three facts that the old single sentence collapsed into one:
      #   * a record at ANOTHER head  → re-record at this head;
      #   * a record AT this head that
      #     is NOT evidence           → the file was read and refused, and the
      #                                 reason is the one that refused it;
      #   * no record at all          → the record was never written here.
      # Before this, the else-arm asserted "record absent" for a file that was
      # PRESENT but unusable (verdict outside the accepted set, another org's
      # repo, a re-serialised head_sha, an unverifiable sig) — unprovability the
      # gate had not verified — and the remedy it printed would overwrite a file
      # that may be the only copy of another repo's verdict (reviewer finding 4).
      if [[ -n "$REVIEW_EVIDENCE_STALE_SHA" ]]; then
        fail c "no head-bound code-review record for $GH_REPO#$PR_NUMBER at the CURRENT head (${PR_HEAD:0:12}…): the on-disk record ${REVIEW_EVIDENCE_STALE_PATH} is bound to ${REVIEW_EVIDENCE_STALE_SHA} but this PR's head is ${PR_HEAD} — a record certifies exactly ONE revision, so accepting it would certify an unreviewed head. No head-bound marker exists in the PR body, comments or commit messages either. [source=none: record=${REVIEW_EVIDENCE_STALE_PATH} (bound to another head), no marker binds ${PR_HEAD:0:12}… in body/comments/commits]"    # #1224 minor finding: the bracket reports what was VERIFIED (no marker binds THIS head), not "absent" — a comment naming an older sha is present, not absent.
        echo "      Missing: a review record for head $PR_HEAD (the record on disk is for ${REVIEW_EVIDENCE_STALE_SHA})."
        echo "      Invoke:  re-record at the current head — record-review.sh <PR> $PR_HEAD <verdict> --evidence <artifact> — which rewrites the record FILE and appends the marker beside it."
      elif [[ -n "$REVIEW_EVIDENCE_RECORD_PRESENT" ]]; then
        fail c "no USABLE head-bound code-review record for $GH_REPO#$PR_NUMBER at the CURRENT head (${PR_HEAD:0:12}…): a record file EXISTS at ${REVIEW_EVIDENCE_RECORD_PRESENT} but it is NOT evidence for this head — ${REVIEW_EVIDENCE_RECORD_REASON:-it was refused}. No head-bound marker exists in the PR body, comments or commit messages either. [source=none: record=${REVIEW_EVIDENCE_RECORD_PRESENT} (unusable), no marker binds ${PR_HEAD:0:12}… in body/comments/commits]"
        echo "      Missing: a review record that BINDS to this head — a file is present but not admissible (${REVIEW_EVIDENCE_RECORD_REASON:-refused}), so this is not a missing record."
        echo "      Invoke:  record-review.sh $PR_NUMBER $PR_HEAD <verdict> --evidence <artifact> — it rewrites the record FILE with the signature the gate requires and appends the marker. Do NOT hand-edit the existing file: it may belong to another repo, and a field patched by hand will not carry a valid signature."
      else
        fail c "no head-bound code-review record for $GH_REPO#$PR_NUMBER — check (c) accepts ONLY the record-review.sh artifact for THIS PR at the CURRENT head (${PR_HEAD:0:12}…): the record file '~/.pi/agent/reviews/${GH_REPO%/*}-${GH_REPO#*/}-$PR_NUMBER.json' (head_sha == $PR_HEAD, signed with AI_REVIEW_GATE_KEY), the same marker line as a PR COMMENT posted by an OWNER/MEMBER/COLLABORATOR (whose sig= must also verify wherever a gate key is available), or that marker line in the PR body/commit messages. A phrase in the PR body or a commit message ('code-review', 'reviewer', 'VGATE', …) is NOT evidence — it names no review, no PR and no revision (#1825). [source=none: record absent at ${HOME:-~}/.pi/agent/reviews, no marker binds ${PR_HEAD:0:12}… in the PR comments, body or commit messages]"
        echo "      Missing: the code-review record for this PR at this head."
        echo "      Invoke:  code-review — Step 10 records the verdict (record-review.sh <PR> <head-sha> <verdict> --evidence <artifact>), which writes the signed head-bound record file, appends the body marker this check falls back to, AND posts that marker as a PR comment — the copy a later body edit cannot wipe. If a record already exists at an OLDER head, re-record at the current one: a record certifies exactly one revision."
      fi
      # #1224 — a marker-SHAPED comment that was REFUSED is a different fact from
      # no comment at all (the review finding that produced
      # REVIEW_EVIDENCE_RECORD_REASON, one artifact over): say which rule refused
      # it, so the reader fixes the right thing instead of hunting for a missing
      # comment that is present.
      if [[ -n "${REVIEW_EVIDENCE_COMMENT_REFUSED:-}" ]]; then
        echo "      Note:    a marker-shaped PR COMMENT was read and REFUSED — ${REVIEW_EVIDENCE_COMMENT_REFUSED}"
      fi
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
  echo "  a. LINKED ISSUE      gh api repos/$GH_REPO/pulls/$PR_NUMBER   → parse PR body for an issue reference that BEGINS A LINE (a Markdown line-leading prefix — bullet, ordered-list marker, blockquote, ATX heading, task-list checkbox, compound prefixes included — or an emphasis/bold/backtick marker may precede; a mid-sentence mention does not count, and can auto-close an issue on merge): EITHER a closing keyword (Fixes/Closes/Resolves #N, owner/repo#N, or full https://github.com/owner/repo/issues/N URL), which auto-closes on merge, OR a non-closing traceability keyword (Refs/Part of/Advances/Tracks/Relates to #N), which does not — accepted for ANY diff (#1630), so a PR implementing only PART of an issue need not lie; the artifact-only class ($ARTIFACT_CLASS_DESC) is no longer required for the traceability form — closure is not implied"
  echo "                      labels + scoping comments are fetched from the issue's OWN repo when it differs from $GH_REPO (cross-repo)"
  echo "  b. SCOPING COMMENT   gh api repos/$GH_REPO/issues/<n>/comments → the '<!-- issue-scoping:' marker as the FIRST content line of a comment, or as its LAST one set off by a blank line (an artifact, not a mention)"
  echo "  c. CODE-REVIEW EVID  gh api repos/$GH_REPO/pulls/$PR_NUMBER + /commits + /issues/$PR_NUMBER/comments → READ RECORD-FIRST (#1224): the head-bound record FILE ~/.pi/agent/reviews/<owner>-<repo>-<PR>.json is consulted first and must carry a sig= that verifies under AI_REVIEW_GATE_KEY (an unauthenticated private file leaves no audit trail, so it is not evidence); the signed marker line in a PR COMMENT is next (comments survive the body edit that wipes the other copy — this is the copy that TRAVELS to a CI runner, whose $HOME has no record store); the PR body/commit marker is the LAST fallback | ⛔ the marker line 'review recorded: reviews/<PR>.json verdict=<v> @ <40-hex head sha> (<owner/repo>)' is accepted from any of the three, so a body edit cannot destroy the proof; the (c) line always prints source=<record|comment|body> | A record whose head_sha is NOT the current head is REFUSED naming both shas, and a record that exists but is unusable is reported as UNUSABLE (with the field that refused it), never as absent | No phrase ('code-review', 'reviewer', 'VGATE', …) satisfies it (#1825) | Two markers carry a VERDICT and are bound: verdict=clean-micro on a non-micro issue fails, and verdict=clean-low is accepted only when the PR's whole diff is in the Low content-shape class sourced from record-review.sh (#513, #1356)"
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
  # #1825 — the check (c) fixtures are RECORD markers BOUND to a live PR
  # identity, because a marker that does not name this PR, this repo and this
  # head is no longer evidence. Offline there is no live PR, so the identity is
  # fixed here (the CI invocation passes PR_NUMBER=1) and every fixture marker
  # is built from it — one definition, so a fixture cannot drift from the
  # binding it is meant to exercise.
  PR_NUMBER="${PR_NUMBER:-1}"
  FIX_HEAD="$(printf 'a%.0s' {1..40})"
  PR_HEAD="$FIX_HEAD"
  # rec_marker <verdict> [<head>] [<repo>] [<pr>] — the producer's marker line.
  # The optional args exist so a fixture can carry the SAME verdict bound to
  # another PR, repo or revision: that is how the negative controls below prove
  # the binding actually reads all three fields instead of trusting the shape.
  rec_marker() {
    printf 'review recorded: reviews/%s.json verdict=%s @ %s (%s)' \
      "${4:-$PR_NUMBER}" "$1" "${2:-$FIX_HEAD}" "${3:-daniel-ospina/agent-infra}"
  }

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
  COMMIT_MSGS="$(rec_marker clean-micro)"
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
  COMMIT_MSGS="$(rec_marker clean-micro)"
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

  # ── #1356 — the clean-low content-shape binding ─────────────────────────
  # Pass 6 and pass 8 run in BOTH environments; passes 7 (the control) needs
  # the shared class and is skipped LOUDLY without it (#991: no silent green).

  # Pass 6 (#1356) — RED pre-binding, GREEN post-binding: a clean-low marker
  # on a CODE-BEARING diff must fail check (c) even though the generic
  # evidence grep matches "review recorded". TWO arms, both fail-closed:
  # class sourced ⇒ the diff is PROVEN not-Low; class absent ⇒ the shape is
  # UNVERIFIABLE. The vector asserts the RIGHT refusal in each environment, so
  # it also pins the fail-closed arm the issue's threat model rests on. This
  # is the vector the SELF_TEST's mutation neuters pr_is_clean_low_shaped to
  # prove load-bearing.
  echo ""
  echo "== SIMULATION: pass 6 (#1356 clean-low binding: code-bearing diff fails c) =="
  PR_BODY="Fixes #1"; LABELS="complexity:standard"; SCOPING_COMMENT=""
  COMMIT_MSGS="$(rec_marker clean-low)"
  FILES=$'added\textensions/example/sample.ts\t'
  FILES_EXPECTED=1
  FAILURES=0
  P6LOG="$(mktemp /tmp/pipeline-pass6.XXXXXX)"
  run_checks > "$P6LOG" 2>&1 || true
  cat "$P6LOG"
  if [[ "$CLEAN_LOW_CLASS_SOURCED" == "true" ]]; then
    P6_WANT='clean-low verdict marker on a diff that is NOT Low-shaped'
  else
    P6_WANT='clean-low verdict marker, but the Low content-shape class could not be read'
  fi
  if grep -qF "$P6_WANT" "$P6LOG" && grep -q '❌ \[c\]' "$P6LOG"; then
    echo "  ✅ pass 6: binding fired — check (c) refused the clean-low marker on the code-bearing diff"
    rm -f "$P6LOG"
  else
    echo "  ❌ pass 6: binding did NOT fire — clean-low marker passed check (c) on a code-bearing diff (wanted: $P6_WANT)" >&2
    rm -f "$P6LOG"
    exit 2
  fi
  summarize || true

  if [[ "$CLEAN_LOW_CLASS_SOURCED" != "true" ]]; then
    echo ""
    echo "== SIMULATION: pass 7 SKIPPED (producer absent: $RECORD_REVIEW_SH) =="
    echo "  ℹ️  the shared Low class could not be sourced, so the shape control is"
    echo "      untestable here. pass 6 already pinned the fail-closed refusal."
  else
    # Pass 7 (#1356) — the CONTROL: the SAME marker on a Low-shaped diff must
    # PASS check (c) with the shape-aware PASS line. Without this control a
    # binding that refused EVERY clean-low marker (e.g. a broken predicate)
    # would still sail through pass 6.
    echo ""
    echo "== SIMULATION: pass 7 (#1356 control: Low-shaped diff passes c) =="
    PR_BODY="Fixes #1"; LABELS="complexity:standard"; SCOPING_COMMENT=""
    COMMIT_MSGS="$(rec_marker clean-low)"
    FILES=$'added\tdocs/guide.md\t'
    FILES_EXPECTED=1
    FAILURES=0
    P7LOG="$(mktemp /tmp/pipeline-pass7.XXXXXX)"
    run_checks > "$P7LOG" 2>&1 || true
    cat "$P7LOG"
    if grep -q 'diff IS Low-shaped' "$P7LOG" \
       && ! grep -q '❌ \[c\]' "$P7LOG"; then
      echo "  ✅ pass 7: control held — a Low-shaped diff passes check (c) with the clean-low marker"
      rm -f "$P7LOG"
    else
      echo "  ❌ pass 7: control FAILED — a Low-shaped diff did not pass check (c) (binding is not shape-sensitive)" >&2
      rm -f "$P7LOG"
      exit 2
    fi
    summarize || true
  fi

  # Pass 8 (#1356 precision, mirroring pass 4b): PROSE that merely mentions
  # "verdict=clean-low" describes the marker contract; it is not a
  # certification, so it must not fire the binding (the marker shape is
  # verdict=… @ <40-hex sha>). Independent of the class, so it runs in both
  # environments.
  echo ""
  echo "== SIMULATION: pass 8 (#1356 precision: prose mention must NOT fire) =="
  PR_BODY="Fixes #1"; LABELS="complexity:standard"; SCOPING_COMMENT=""
  COMMIT_MSGS="code-review dispatched; the binding rejects commits claiming verdict=clean-low (marker shape only)"
  FILES=$'added\textensions/example/sample.ts\t'
  FILES_EXPECTED=1
  FAILURES=0
  P8LOG="$(mktemp /tmp/pipeline-pass8.XXXXXX)"
  run_checks > "$P8LOG" 2>&1 || true
  if grep -q 'clean-low verdict marker' "$P8LOG"; then
    echo "  ❌ pass 8: prose mention fired the binding — check (c) must match only the marker shape (verdict=… @ <40-hex>)" >&2
    rm -f "$P8LOG"
    exit 2
  else
    echo "  ✅ pass 8: prose mention did NOT fire — binding precision holds"
    rm -f "$P8LOG"
  fi
  summarize || true

  # ── #1825 — the fail-open this issue measured: A PHRASE IS NOT EVIDENCE ────
  # Pass 9 is the vector the issue reports. Pre-#1825 it PASSED check (c) with
  # NO review behind it, because (c) was a substring alternation over the PR
  # body and the commit messages: all six accepted tokens are present here and
  # nothing else is, so the pre-fix gate reported "code-review evidence in PR
  # body/commits (review dispatch marker)". It is the fixture PR #1822's own
  # shape (a commit message that says `review recorded: code-review dispatch
  # marker …`) generalised. Post-fix (c) must FAIL, and must fail by NAMEING
  # the missing artifact, never by silently grading something else.
  echo ""
  echo "== SIMULATION: pass 9 (#1825: a review-dispatch PHRASE is not evidence) =="
  PR_BODY="Fixes #1"; LABELS="complexity:standard"
  SCOPING_COMMENT='<!-- issue-scoping: 2026-10-17 (standard) -->'
  COMMIT_MSGS="code-review dispatched; reviewer ran; [review]; VGATE; review recorded; review-enforcer"
  FILES=$'added	docs/plans/2026-10-17-issue-1825-review-check-evidence.md	'
  FILES_EXPECTED=1
  FAILURES=0
  P9LOG="$(mktemp /tmp/pipeline-pass9.XXXXXX)"
  run_checks > "$P9LOG" 2>&1 || true
  B9="$FAILURES"
  if [[ "$B9" -eq 1 ]] && grep -q 'no head-bound code-review record' "$P9LOG"; then
    echo "  ✅ pass 9: the phrase did NOT satisfy (c) — check (c) failed naming the missing head-bound record"
    rm -f "$P9LOG"
  else
    echo "  ❌ pass 9: a review-dispatch phrase still satisfies check (c) (failures=$B9) — the #1825 fail-open is OPEN" >&2
    grep -E '❌ \[c\]|✅ \[c\]' "$P9LOG" >&2 || true
    rm -f "$P9LOG"
    exit 2
  fi
  summarize || true

  # Pass 10 — the POSITIVE CONTROL for pass 9, so a matcher that refused
  # EVERYTHING could not satisfy it: the same body plus the producer's marker
  # for THIS PR at THIS head must leave check (c) the only passing part of a
  # clean run (0 failures overall, since the scoping comment and the plan doc
  # are present and the diff is prose-only).
  echo ""
  echo "== SIMULATION: pass 10 (#1825 control: the head-bound record DOES satisfy c) =="
  PR_BODY="Fixes #1"; LABELS="complexity:standard"
  SCOPING_COMMENT='<!-- issue-scoping: 2026-10-17 (standard) -->'
  COMMIT_MSGS="$(rec_marker clean)"
  FILES=$'added	docs/plans/2026-10-17-issue-1825-review-check-evidence.md	'
  FILES_EXPECTED=1
  FAILURES=0
  P10LOG="$(mktemp /tmp/pipeline-pass10.XXXXXX)"
  run_checks > "$P10LOG" 2>&1 || true
  B10="$FAILURES"
  if [[ "$B10" -eq 0 ]] && grep -q 'code-review record bound to' "$P10LOG"; then
    echo "  ✅ pass 10: control held — the head-bound record satisfies (c) with 0 failures"
    rm -f "$P10LOG"
  else
    echo "  ❌ pass 10: the head-bound record did NOT satisfy (c) (failures=$B10) — the matcher refuses real evidence too" >&2
    grep -E '❌ \[c\]|✅ \[c\]' "$P10LOG" >&2 || true
    rm -f "$P10LOG"
    exit 2
  fi
  summarize || true

  # Passes 11–14 — THE BINDING READS ALL THREE FIELDS. A marker that has the
  # right SHAPE but names another PR, another repo, or another revision is not
  # evidence for this one: each is a mutation of exactly one field of the pass
  # 10 fixture, so a binding that quietly dropped a comparison would leave one
  # of these four vectors green (a partial binding is how a "head-bound" claim
  # becomes decorative).
  P11_FAILS=0
  pass_bound_field() { # pass_bound_field <label> <marker-line>
    local label="$1" marker="$2" log n
    PR_BODY="Fixes #1"; LABELS="complexity:standard"
    SCOPING_COMMENT='<!-- issue-scoping: 2026-10-17 (standard) -->'
    COMMIT_MSGS="$marker"
    FILES=$'added	docs/plans/2026-10-17-issue-1825-review-check-evidence.md	'
    FILES_EXPECTED=1
    FAILURES=0
    log="$(mktemp /tmp/pipeline-boundfield.XXXXXX)"
    run_checks > "$log" 2>&1 || true
    n="$FAILURES"
    if [[ "$n" -eq 1 ]] && grep -q 'no head-bound code-review record' "$log"; then
      echo "  ✅ $label: refused (check c failed — the field is compared)"
      rm -f "$log"
      return 0
    fi
    echo "  ❌ $label: ACCEPTED — the marker's field is not compared, so the binding is partial" >&2
    grep -E '❌ \[c\]|✅ \[c\]' "$log" >&2 || true
    rm -f "$log"
    return 1
  }
  echo ""
  echo "== SIMULATION: passes 11–14 (#1825: the binding compares PR, repo AND head) =="
  pass_bound_field "another PR number" "$(rec_marker clean "" "" "$((PR_NUMBER + 1))")" || P11_FAILS=$((P11_FAILS + 1))
  pass_bound_field "another repo" "$(rec_marker clean "" "daniel-ospina/tortoise")" || P11_FAILS=$((P11_FAILS + 1))
  pass_bound_field "an earlier head" "$(rec_marker clean "$(printf 'b%.0s' {1..40})")" || P11_FAILS=$((P11_FAILS + 1))
  # A marker without the `sig=`/`diff=` optional fields is the LEGACY shape and
  # MUST still be accepted (the producer's older records carry neither), so the
  # regex's optional groups cannot become a requirement by accident.
  PR_BODY="Fixes #1"; LABELS="complexity:standard"
  SCOPING_COMMENT='<!-- issue-scoping: 2026-10-17 (standard) -->'
  COMMIT_MSGS="$(rec_marker clean)"
  FILES=$'added\tdocs/plans/2026-10-17-issue-1825-review-check-evidence.md\t'
  FILES_EXPECTED=1
  FAILURES=0
  P14LOG="$(mktemp /tmp/pipeline-pass14.XXXXXX)"
  run_checks > "$P14LOG" 2>&1 || true
  if [[ "$FAILURES" -eq 0 ]] && grep -q 'code-review record bound to' "$P14LOG"; then
    echo "  ✅ the legacy marker shape (no diff=/sig=) is accepted — the optional groups stayed optional"
  else
    echo "  ❌ the legacy shape was refused (failures=$FAILURES) — diff=/sig= must stay OPTIONAL (older records would stop counting)" >&2
    P11_FAILS=$((P11_FAILS + 1))
  fi
  rm -f "$P14LOG"
  if [[ "$P11_FAILS" -ne 0 ]]; then
    echo "  ❌ passes 11–14: $P11_FAILS field-binding assertion(s) failed" >&2
    exit 2
  fi
  summarize || true

  # ── #1224 — THE RECORD-FIRST READ: the red-to-green case, the refusal that
  # must survive the fix, and the fallback that keeps in-flight PRs working ──
  #
  # THE MEASURED DEFECT. The attestation lived only in the PR body, so a later
  # body edit — a typo fix, a corrected claim, the closing keyword that
  # `pipeline-compliance` itself demands — destroyed it, and check (c) went RED
  # on a review that genuinely happened (agent-infra#1209 and premise-labs#3788,
  # both 2026-09-18). The record FILE is head-bound and the PR cannot edit it, so
  # (c) now reads it FIRST and falls back to the body only when it is absent.
  #
  #   1224a  body marker WIPED + SIGNED on-disk record for THIS head  ⇒ PASS,
  #          source=record.  THIS IS THE RED-TO-GREEN CASE: it is the population
  #          the issue measures (the NO_MARKER class), and it must move from red
  #          to green — not the other way while looking green.
  #   1224b  record bound to a DIFFERENT head, no marker anywhere ⇒ FAIL, naming
  #          BOTH shas. The refusal the fix must never relax: a record certifies
  #          one revision, and accepting a stale one certifies an UNREVIEWED head.
  #   1224c  NO record at all + body marker at this head ⇒ PASS, source=body.
  #          The fallback control: every in-flight PR, and every box whose store
  #          was never written, keeps working — so this change cannot strand a
  #          PR that is green today.
  #   1224d  NO record at all + the producer's SIGNED marker COMMENT (in the fetch's
  #          own `<association>\x1f<body>\x1e` frame), body WIPED ⇒ PASS,
  #          source=comment. #1224 review finding 2: the record store is PER BOX,
  #          so on the required `pipeline-compliance` check (a clean ubuntu-latest
  #          runner with no ~/.pi/agent/reviews) the record arm can never answer.
  #          Without this arm the whole fix is inert in the only environment whose
  #          verdict blocks a merge — which is exactly what this PR's own head
  #          measured (`source=none: record absent at /home/runner/.pi/...`).
  #   1224e  an UNSIGNED record at this head, nothing else ⇒ FAIL, and the refusal
  #          says so. #1224 review finding 3: a private, per-box file that leaves
  #          no audit trail on the PR is below the bar the producer already sets
  #          for the artifact that travels (a signed marker), so it is not evidence
  #          by shape alone.
  #   1224f  a record at this head whose verdict is OUTSIDE the accepted set ⇒
  #          FAIL, and the refusal reports UNUSABLE with the field that refused it.
  #          #1224 review finding 4: REVIEW_EVIDENCE_RECORD_PRESENT was documented
  #          and written but read nowhere, so a present-but-unusable record was
  #          reported as "absent" — an unprovability the gate had not verified.
  #   1224g/h/i/j  THE COMMENT ARM'S ADMISSION AND VERDICT — see the block above
  #          those passes: an unsigned comment, an untrusted author, a stale
  #          clean-micro elsewhere in the stream, and the no-gate-key (CI) path.
  #
  # Each pass runs under its OWN $HOME: an ambient record on the machine RUNNING
  # the suite would let 1224a pass for the wrong reason and make 1224c
  # unreachable. Failures ACCUMULATE (no early exit) so the SELF_TEST can show
  # which mutation flipped which pass, and that the OTHER passes stayed green.
  P1224_FAILS=0
  P1224_BASE="$(mktemp -d "${TMPDIR:-/tmp}/pipeline-1224.XXXXXX")"
  P1224_ALT="$(printf 'b%.0s' {1..40})"
  # The fixture gate key: the vectors exercise the REAL signature path, so a
  # `sig` requirement that drifted from the producer's canonical text fails here
  # instead of passing on a hand-written file.
  P1224_KEY="pipeline-compliance-1224-fixture-key"
  p1224_sig() { # p1224_sig_pr <pr> <head> <verdict> <repo> — the producer's canonical sig
    printf '%s' "review-record:v1:$1:$2:$3:$4" \
      | command openssl dgst -sha256 -hmac "$P1224_KEY" 2>/dev/null | command awk '{print $NF}'
  }
  p1224_record() { # p1224_record <home> <head> <verdict> [sig-override]
    local sig
    mkdir -p "$1/.pi/agent/reviews"
    if [ -n "${4-}" ]; then sig="$4"; else sig="$(p1224_sig "$PR_NUMBER" "$2" "$3" "$GH_REPO")"; fi
    printf '{"pr":%d,"head_sha":"%s","verdict":"%s","repo":"%s","reviewed_at":"2026-09-18T00:00:00Z","sig":"%s"}\n' \
      "$PR_NUMBER" "$2" "$3" "$GH_REPO" "$sig" > "$1/.pi/agent/reviews/${GH_REPO%/*}-${GH_REPO#*/}-$PR_NUMBER.json"
  }
  p1224_fixtures() { # p1224_fixtures <body> <commits> [comments] — a PR whose ONLY question is (c)
    PR_BODY="$1"; LABELS="complexity:standard"
    SCOPING_COMMENT='<!-- issue-scoping: 2026-09-18 (standard) -->'
    COMMIT_MSGS="$2"
    PR_COMMENTS="${3-}"
    FILES=$'added\tdocs/plans/2026-09-18-issue-1224-review-record-source.md\t'
    FILES_EXPECTED=1
    FAILURES=0
  }
  p1224_run() { # p1224_run <home> <log> — run_checks against a given record store
    local home="$1" log="$2" saved_home="$HOME"
    HOME="$home"
    run_checks > "$log" 2>&1 || true
    HOME="$saved_home"
  }
  # ── THE COMMENT ARM'S TRANSPORT-FAITHFUL FIXTURES ──────────────────────────
  # Every comment fixture is built from REVIEW_COMMENTS_JQ's OWN frame
  # (`<association>\x1f<body>\x1e`), not hand-written to look like a marker.
  # That is the whole point: 1224d used to hand `PR_COMMENTS` a BARE marker, a
  # shape the live fetch never produces, so it stayed green while the production
  # arm — whose marker line ends at `sig=<64hex><0x1e>` — could never match. A
  # vector that bypasses the transport cannot see the transport, and this is the
  # #633 rule (model the TRANSPORT, not just the URL) applied to a fixture.
  p1224_comment() { # p1224_comment <author_association> <body> — one comment, production frame
    printf '%s%s%s%s' "$1" "$REVIEW_COMMENTS_ASSOC_SEP" "$2" "$REVIEW_COMMENTS_REC_SEP"
  }
  # ⛔ AND THE FRAME IS BOUND TO THE EXPRESSION ITSELF, not to a second copy of its
  # bytes. REVIEW_COMMENTS_JQ spells its two separators as jq escapes, so a change
  # to the EXPRESSION alone (say 0x1f → 0x7c) would leave the constants — and every
  # vector built from them — describing a transport the gate no longer has, which
  # is the P1 the vectors exist to catch, one level up. This runs the PRODUCTION
  # expression over a synthesized API page and requires its output to be
  # byte-identical to the frame the fixtures build, so the two definitions cannot
  # drift silently. jq is a hard dependency of the fetch path (`gh api --jq`), and
  # a box without it CANNOT verify this: that is reported as a failure, never as
  # a pass.
  p1224_frame_is_production() {
    local body got want
    if ! command -v jq >/dev/null 2>&1; then
      echo "no 'jq' on this box, so the comment fixtures were NOT proved identical to REVIEW_COMMENTS_JQ's output — install jq (the fetch path's own dependency) and re-run" >&2
      return 1
    fi
    body="review recorded: reviews/$PR_NUMBER.json verdict=clean @ $FIX_HEAD ($GH_REPO)"
    got="$(printf '[{"author_association":"OWNER","body":%s}]' "$(printf '%s' "$body" | jq -Rs .)" | jq -r "$REVIEW_COMMENTS_JQ")"
    want="$(p1224_comment OWNER "$body")"
    [ "$got" = "$want" ]
  }
  # p1224_marker <verdict> [<head>] — the producer's SIGNED marker line. Note the
  # signed text: it is the MARKER UP TO ` sig=`, NOT the record's
  # `review-record:v1:` canonical text — that is what record-review.sh signs for
  # the marker and what merge-one.sh::verify_any_marker verifies, so a consumer
  # that used the record computation here would fail this vector.
  p1224_marker() {
    local v="$1" h="${2:-$FIX_HEAD}" body sig
    body="review recorded: reviews/$PR_NUMBER.json verdict=$v @ $h ($GH_REPO)"
    sig="$(printf '%s' "$body" | command openssl dgst -sha256 -hmac "$P1224_KEY" 2>/dev/null | command awk '{print $NF}' || true)"
    printf '%s sig=%s' "$body" "$sig"
  }
  AI_REVIEW_GATE_KEY="$P1224_KEY"

  echo ""
  echo "== SIMULATION: pass 1224a (#1224: body attestation WIPED, on-disk record intact → (c) PASSES) =="
  p1224_record "$P1224_BASE/a" "$FIX_HEAD" clean
  p1224_fixtures "Fixes #1" ""
  p1224_run "$P1224_BASE/a" "$P1224_BASE/a.log"
  if [[ "$FAILURES" -eq 0 ]] && grep -q '✅ \[c\].*source=record' "$P1224_BASE/a.log"; then
    echo "  ✅ pass 1224a: (c) PASSED from the on-disk record with NO body marker (0 failures, source=record)"
  else
    echo "  ❌ pass 1224a: the on-disk record at THIS head did NOT satisfy check (c) (failures=$FAILURES) — the #1224 red-to-green case is broken" >&2
    grep -E '❌ \[c\]|✅ \[c\]' "$P1224_BASE/a.log" >&2 || true
    P1224_FAILS=$((P1224_FAILS + 1))
  fi

  echo ""
  echo "== SIMULATION: pass 1224b (#1224: record bound to ANOTHER head → (c) REFUSES, naming both shas) =="
  p1224_record "$P1224_BASE/b" "$P1224_ALT" clean
  p1224_fixtures "Fixes #1" ""
  p1224_run "$P1224_BASE/b" "$P1224_BASE/b.log"
  if [[ "$FAILURES" -eq 1 ]] \
    && grep -q '❌ \[c\]' "$P1224_BASE/b.log" \
    && grep -q "$P1224_ALT" "$P1224_BASE/b.log" \
    && grep -q "$FIX_HEAD" "$P1224_BASE/b.log"; then
    echo "  ✅ pass 1224b: a record bound to ${P1224_ALT:0:12}… was REFUSED for head ${FIX_HEAD:0:12}…, with BOTH shas named (1 failure)"
  else
    echo "  ❌ pass 1224b: a record bound to ANOTHER head was ACCEPTED, or the refusal did not name both shas (failures=$FAILURES) — a stale record would certify an unreviewed head" >&2
    grep -E '❌ \[c\]|✅ \[c\]' "$P1224_BASE/b.log" >&2 || true
    P1224_FAILS=$((P1224_FAILS + 1))
  fi

  echo ""
  echo "== SIMULATION: pass 1224c (#1224 fallback: NO record at all → the body attestation still PASSES) =="
  mkdir -p "$P1224_BASE/c"   # a HOME with NO ~/.pi/agent/reviews at all
  p1224_fixtures "Fixes #1" "$(rec_marker clean)"
  p1224_run "$P1224_BASE/c" "$P1224_BASE/c.log"
  if [[ "$FAILURES" -eq 0 ]] && grep -q '✅ \[c\].*source=body' "$P1224_BASE/c.log"; then
    echo "  ✅ pass 1224c: with no record on disk the body marker still satisfied (c) (0 failures, source=body)"
  else
    echo "  ❌ pass 1224c: the body FALLBACK stopped working (failures=$FAILURES) — every in-flight PR whose only record is the body would be stranded" >&2
    grep -E '❌ \[c\]|✅ \[c\]' "$P1224_BASE/c.log" >&2 || true
    P1224_FAILS=$((P1224_FAILS + 1))
  fi

  echo ""
  echo "== SIMULATION: pass 1224T (#1224: the comment fixture IS the production fetch expression's output) =="
  if p1224_frame_is_production; then
    echo "  ✅ pass 1224T: the fixture's comment frame is BYTE-IDENTICAL to what REVIEW_COMMENTS_JQ emits for a live API page (association 0x1f body 0x1e) — the vectors below cannot drift from the transport they model"
  else
    echo "  ❌ pass 1224T: the comment fixtures do NOT describe the production fetch frame — REVIEW_COMMENTS_JQ and the p1224_comment separators have diverged, so every comment vector below grades a transport the gate does not have (#1224 P1, the fixture-bypasses-the-transport class)" >&2
    P1224_FAILS=$((P1224_FAILS + 1))
  fi

  echo ""
  echo "== SIMULATION: pass 1224d (#1224: body WIPED, record store ABSENT, the producer's SIGNED marker comment → (c) PASSES) =="
  mkdir -p "$P1224_BASE/d"   # a clean-runner $HOME: no ~/.pi/agent/reviews at all
  # ⛔ THE PRODUCTION SHAPE, INCLUDING THE 0x1e TERMINATOR. Before this, the
  # fixture passed the BARE marker while the live fetch appends 0x1e to every
  # body — so the vector proved a value the transport never produces and stayed
  # green over a dead arm (the review's P1 #1). A change to the separator now
  # reds THIS pass instead of silently disabling the arm.
  p1224_fixtures "Fixes #1" "" "$(p1224_comment OWNER "$(p1224_marker clean)")"
  p1224_run "$P1224_BASE/d" "$P1224_BASE/d.log"
  if [[ "$FAILURES" -eq 0 ]] && grep -q '✅ \[c\].*source=comment.*sig verified' "$P1224_BASE/d.log"; then
    echo "  ✅ pass 1224d: (c) PASSED from the producer's OWN comment frame (association + signed marker + 0x1e) with no record store on the box (0 failures, source=comment, sig verified) — the arm that reaches CI"
  else
    echo "  ❌ pass 1224d: the producer's marker COMMENT did not satisfy (c) (failures=$FAILURES) — the fix is inert on the required check, whose runner has no record store (#1224 finding 2), or the transport shape is not handled" >&2
    grep -E '❌ \[c\]|✅ \[c\]|Note:' "$P1224_BASE/d.log" >&2 || true
    P1224_FAILS=$((P1224_FAILS + 1))
  fi

  echo ""
  echo "== SIMULATION: pass 1224e (#1224: UNSIGNED record at this head, nothing else → (c) REFUSES) =="
  p1224_record "$P1224_BASE/e" "$FIX_HEAD" clean "0000000000000000000000000000000000000000000000000000000000000000"
  p1224_fixtures "Fixes #1" ""
  p1224_run "$P1224_BASE/e" "$P1224_BASE/e.log"
  if [[ "$FAILURES" -eq 1 ]] && grep -q '❌ \[c\]' "$P1224_BASE/e.log" \
    && grep -q 'NOT evidence' "$P1224_BASE/e.log" \
    && grep -q 'does not verify' "$P1224_BASE/e.log"; then
    echo "  ✅ pass 1224e: a record at THIS head whose sig= does not verify was REFUSED as not-evidence (1 failure) — a private file with no audit trail is not evidence by shape"
  else
    echo "  ❌ pass 1224e: an UNSIGNED/unverifiable record was ACCEPTED as evidence (failures=$FAILURES) — a hand-written file at the store path would satisfy (c) with nothing in the PR to audit (#1224 finding 3)" >&2
    grep -E '❌ \[c\]|✅ \[c\]' "$P1224_BASE/e.log" >&2 || true
    P1224_FAILS=$((P1224_FAILS + 1))
  fi

  echo ""
  echo "== SIMULATION: pass 1224f (#1224: record present but UNUSABLE → refusal says UNUSABLE, never 'absent') =="
  p1224_record "$P1224_BASE/f" "$FIX_HEAD" wip   # a verdict outside clean|clean-micro|clean-low
  p1224_fixtures "Fixes #1" ""
  p1224_run "$P1224_BASE/f" "$P1224_BASE/f.log"
  if [[ "$FAILURES" -eq 1 ]] && grep -q '❌ \[c\]' "$P1224_BASE/f.log" \
    && grep -q 'exists' "$P1224_BASE/f.log" \
    && grep -q "its verdict is 'wip'" "$P1224_BASE/f.log" \
    && ! grep -q 'record absent at' "$P1224_BASE/f.log"; then
    echo "  ✅ pass 1224f: a record file that EXISTS but is not evidence is reported as UNUSABLE with the field that refused it — not as 'record absent' (#1224 finding 4)"
  else
    echo "  ❌ pass 1224f: a present-but-unusable record was reported as ABSENT (or the reason was not named) (failures=$FAILURES) — the gate asserts unprovability it never verified" >&2
    grep -E '❌ \[c\]|✅ \[c\]' "$P1224_BASE/f.log" >&2 || true
    P1224_FAILS=$((P1224_FAILS + 1))
  fi

  # ── THE COMMENT ARM'S ADMISSION AND ITS VERDICT (fresh-review findings) ────
  # The arm 1224d proves EXISTS is only safe if it admits the RIGHT comments and
  # reads the RIGHT verdict. Three vectors, each RED on the pre-fix code:
  #   1224g  an UNSIGNED marker comment from a trusted author, a gate key present
  #          ⇒ FAIL. Before the fix the optional `sig=` group made any typed line
  #          evidence, i.e. a credential-free bypass of the repo's only required
  #          check on a PUBLIC repo.
  #   1224h  a VALIDLY SIGNED marker comment from an UNTRUSTED author
  #          (`author_association: NONE`, what any outside account gets) ⇒ FAIL.
  #          Before the fix `PR_COMMENTS` was `.[].body` for every comment, so
  #          anyone could satisfy (c); the fetch now carries the association and
  #          the arm admits only OWNER/MEMBER/COLLABORATOR — the same constant the
  #          #1224 decision comment fixes as the shared contract.
  #   1224i  a signed clean marker comment PLUS a separate stale
  #          `verdict=clean-micro @ 0000…` comment ⇒ PASS as clean. Before the
  #          fix the verdict was a whole-blob grep, so the junk line pinned the
  #          #513 tier binding to micro and RED-ed (c) on a non-micro issue — a
  #          public off-switch on any PR, in an append-only stream.
  #   1224j  NO gate key on the box (what the required check's runner has: its
  #          workflow passes no AI_REVIEW_GATE_KEY and this repo has no such
  #          secret) + a trusted-author marker comment ⇒ PASS, source=comment
  #          with `no gate key on this box` said out loud. This is the CI path:
  #          requiring a verifiable sig with no key would make the arm inert
  #          again, which is the defect 1224d exists to prevent.
  echo ""
  echo "== SIMULATION: pass 1224g (#1224: UNSIGNED marker comment from a trusted author → (c) REFUSES) =="
  mkdir -p "$P1224_BASE/g"
  p1224_fixtures "Fixes #1" "" "$(p1224_comment OWNER "$(rec_marker clean)")"
  p1224_run "$P1224_BASE/g" "$P1224_BASE/g.log"
  if [[ "$FAILURES" -eq 1 ]] && grep -q '❌ \[c\]' "$P1224_BASE/g.log" \
    && grep -q 'source=none' "$P1224_BASE/g.log" \
    && grep -q 'sig= does not verify' "$P1224_BASE/g.log"; then
    echo "  ✅ pass 1224g: an UNSIGNED marker comment was REFUSED, and the refusal names the sig rule (1 failure) — a comment is not evidence by shape"
  else
    echo "  ❌ pass 1224g: an UNSIGNED marker comment satisfied (c) (failures=$FAILURES) — any account that can comment could satisfy the ONLY required check with no review behind it" >&2
    grep -E '❌ \[c\]|✅ \[c\]|Note:' "$P1224_BASE/g.log" >&2 || true
    P1224_FAILS=$((P1224_FAILS + 1))
  fi

  echo ""
  echo "== SIMULATION: pass 1224h (#1224: SIGNED marker comment from an UNTRUSTED author_association → (c) REFUSES) =="
  mkdir -p "$P1224_BASE/h"
  p1224_fixtures "Fixes #1" "" "$(p1224_comment NONE "$(p1224_marker clean)")"
  p1224_run "$P1224_BASE/h" "$P1224_BASE/h.log"
  if [[ "$FAILURES" -eq 1 ]] && grep -q '❌ \[c\]' "$P1224_BASE/h.log" \
    && grep -q "author_association is 'NONE'" "$P1224_BASE/h.log"; then
    echo "  ✅ pass 1224h: a marker comment from an author GitHub does NOT attest as OWNER/MEMBER/COLLABORATOR was REFUSED (1 failure) — the comment arm's admission rule is the author, not the text"
  else
    echo "  ❌ pass 1224h: an UNTRUSTED commenter satisfied (c) (failures=$FAILURES) — on a public repo any GitHub account could post the marker and defeat the gate (#1224 P0)" >&2
    grep -E '❌ \[c\]|✅ \[c\]|Note:' "$P1224_BASE/h.log" >&2 || true
    P1224_FAILS=$((P1224_FAILS + 1))
  fi

  echo ""
  echo "== SIMULATION: pass 1224i (#1224: the verdict comes from the marker LINE, not from a stale clean-micro elsewhere) =="
  mkdir -p "$P1224_BASE/i"
  p1224_fixtures "Fixes #1" "" "$(p1224_comment OWNER "$(p1224_marker clean)")$(p1224_comment OWNER "a review note quoting a stale marker: verdict=clean-micro @ $(printf '0%.0s' {1..40})")"
  p1224_run "$P1224_BASE/i" "$P1224_BASE/i.log"
  if [[ "$FAILURES" -eq 0 ]] && grep -q '✅ \[c\].*source=comment' "$P1224_BASE/i.log" \
    && ! grep -q 'clean-micro verdict marker on a NON-micro' "$P1224_BASE/i.log"; then
    echo "  ✅ pass 1224i: a stale verdict=clean-micro line elsewhere in the stream did NOT become this head's verdict (0 failures) — the #513 tier binding reads the matched line (#1224 P1)"
  else
    echo "  ❌ pass 1224i: a stale clean-micro line in the comment stream pinned the verdict for THIS head (failures=$FAILURES) — a public off-switch on every non-micro PR, in a stream nobody can edit" >&2
    grep -E '❌ \[c\]|✅ \[c\]' "$P1224_BASE/i.log" >&2 || true
    P1224_FAILS=$((P1224_FAILS + 1))
  fi

  echo ""
  echo "== SIMULATION: pass 1224j (#1224: no gate key on the box — the CI runner — still admits a TRUSTED author's marker) =="
  mkdir -p "$P1224_BASE/j"
  p1224_fixtures "Fixes #1" "" "$(p1224_comment MEMBER "$(p1224_marker clean)")"
  AI_REVIEW_GATE_KEY=""
  p1224_run "$P1224_BASE/j" "$P1224_BASE/j.log"
  AI_REVIEW_GATE_KEY="$P1224_KEY"
  if [[ "$FAILURES" -eq 0 ]] && grep -q '✅ \[c\].*source=comment.*no gate key on this box' "$P1224_BASE/j.log"; then
    echo "  ✅ pass 1224j: with NO gate key (the required check's runner) a trusted author's marker comment still answers, and the (c) line says the sig could not be verified (0 failures) — the authenticated-where-possible rule never makes the arm inert"
  else
    echo "  ❌ pass 1224j: with no gate key a trusted author's marker comment did NOT satisfy (c) (failures=$FAILURES) — requiring a sig nobody can produce would make the arm inert on the required check, the very defect #1224 fixes" >&2
    grep -E '❌ \[c\]|✅ \[c\]|Note:' "$P1224_BASE/j.log" >&2 || true
    P1224_FAILS=$((P1224_FAILS + 1))
  fi

  if [[ "$P1224_FAILS" -ne 0 ]]; then
    echo "  ❌ passes 1224a–j: $P1224_FAILS record-source assertion(s) failed" >&2
    exit 2
  fi
  unset AI_REVIEW_GATE_KEY
  rm -rf "$P1224_BASE"
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
    # Split declaration, then assignment: the declaration form hides the status of the
    # substitution from `$?` (the `discarded-status` shape the repo now bans).
    local input="$1" want="$3" got intended
    intended="$(printf '%s' "${GH_REPO}#$2" | tr '[:upper:]' '[:lower:]')"
    got="$(scan_close_word_hazards "$input" "$intended")"
    if { [[ "$want" == "yes" && -n "$got" ]] || [[ "$want" == "no" && -z "$got" ]]; }; then
      printf '✅ scan_close_word_hazards(%q, %s) → hazards=%s\n' "$input" "$intended" "$want"
    else
      printf '❌ scan_close_word_hazards(%q, %s) → want hazards=%s, got %q\n' "$input" "$intended" "$want" "$got" >&2
      selffail=$((selffail + 1))
    fi
  }
  # The ADVISORY half. Never a failure, so a wrong answer here costs a note.
  expect_note() {
    # Split declaration, then assignment: the declaration form hides the status of the
    # substitution from `$?` (the `discarded-status` shape the repo now bans).
    local input="$1" want="$3" got intended
    intended="$(printf '%s' "${GH_REPO}#$2" | tr '[:upper:]' '[:lower:]')"
    got="$(close_word_notes "$input" "$intended")"
    if { [[ "$want" == "yes" && -n "$got" ]] || [[ "$want" == "no" && -z "$got" ]]; }; then
      printf '✅ close_word_notes(%q, %s) → note=%s\n' "$input" "${GH_REPO}#$2" "$want"
    else
      printf '❌ close_word_notes(%q, %s) → want note=%s, got %q\n' "$input" "${GH_REPO}#$2" "$want" "$got" >&2
      selffail=$((selffail + 1))
    fi
  }
  # normalize_ref directly — the qualifier the blocking compare depends on.
  expect_normalize() {
    local input="$1" want="$2" got
    got="$(normalize_ref "$input")"
    if [[ "$got" == "$want" ]]; then
      printf '✅ normalize_ref(%q) → %s\n' "$input" "$got"
    else
      printf '❌ normalize_ref(%q) → want %s, got %s\n' "$input" "$want" "$got" >&2
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
  expect_hazard '`Closes #173`' 173 no
  expect_note '`Closes #173`' 173 yes
  # Precision: an INERT mention of some OTHER issue is neither closure nor
  # disarmed intent — flagging it would be noise, and noise is how a gate gets
  # routed around.
  expect_hazard $'Closes #173\nsee `Closes #174` for how the keyword works' 173 yes
  # ==== adversarial review, cycle 1 — four findings, all reproduced ====
  # P1 — the span regex paired ANY two backticks, so two inline spans on one line
  # disguised a LIVE unintended closure as inert. Nothing is subtracted now.
  expect_hazard $'Closes #173\nThe `fleet` note says this also Closes #174 (see `docs/ops`).' 173 yes
  # P2 — the inert set held NUMBERS, so one inert mention of N disarmed the report
  # for every live mention of N.
  expect_hazard $'Closes #173\nAlso Closes #174.\nNote: `Closes #174` was the historical form.' 173 yes
  # P3 — refs were compared as bare numbers, so a cross-repo ref and a local one
  # sharing a number collapsed and the unintended local closure went unreported.
  expect_hazard $'Closes other/repo#173\nAlso closes #173 in the local repo' 173 yes
  # P4 — a live intended keyword AND a backticked quotation of it used to be
  # REFUSED, with a message asserting the link would not be created. Now there is
  # no H1, and the consequence is a hedged note rather than a false failure.
  expect_hazard $'Closes #173\nThe `Closes #173` form is what GitHub reads.' 173 no
  expect_note $'Closes #173\nThe `Closes #173` form is what GitHub reads.' 173 yes
  expect_note 'Closes #173' 173 no
  # ==== cycle 2 — both reviewers independently reproduced these two ====
  # A FALSE BLOCK in normalize_ref: the URL branch matched case-sensitively, so a
  # capitalised host never qualified and the body's OWN intended issue was
  # reported as an unintended close.
  expect_normalize 'https://GitHub.com/Daniel-Ospina/Agent-Infra/issues/173' 'daniel-ospina/agent-infra#173'
  expect_normalize 'HTTPS://GITHUB.COM/owner/repo/issues/173' 'owner/repo#173'
  # ...and the greedy suffix strip ate a repository named "issues".
  expect_normalize 'https://github.com/owner/issues/issues/173' 'owner/issues#173'
  # The end-to-end shape: a capitalised intended URL must not be refused.
  expect_hazard 'Closes https://GitHub.com/daniel-ospina/agent-infra/issues/173' 173 no
  # The keyword class is a SUFFIX of ordinary words: prose that closes nothing
  # must not manufacture a hazard.
  expect_hazard $'Closes #173\nthe prefix #99 discloses #98' 173 no
  # ==== #1336 — underscore-emphasis `_Closes #N_` ====
  # GitHub CLOSES `_Closes #N_`, but the hazard scan was blind to it: `\b` does
  # not fire after `_` (`_` is a WORD character), while check (a)'s REFCTX DOES
  # resolve the shape — so the scan and the admission bar disagreed and the
  # shape could never become a hazard, i.e. a PR body could close an unintended
  # issue with the gate green. Measured against GitHub's own
  # closingIssuesReferences on scratch repo ai-gate-semantics-test PR #13.
  # The intended ref wrapped in emphasis: no hazard (all it names is #173).
  expect_hazard '_Closes #173_' 173 no
  # An EXTRA ref wrapped in emphasis: THE fail-open. RED pre-fix (no hazard).
  expect_hazard $'Closes #173\n_Closes #174_' 173 yes
  expect_hazard $'Closes #173\n__Closes #174__' 173 yes
  expect_hazard $'Closes #173\nThe old _Closes #174_ form is documented.' 173 yes
  # GitHub-parity NEGATIVE controls — both are IGNORED by GitHub, so a hazard
  # here would be a FALSE block: an INTRA-WORD underscore (`foo_closes`) is not
  # an emphasis opener, and a CLOSING emphasis marker between the keyword and the
  # ref is not stripped. The `[^[:alnum:]_]` class is what keeps `foo_closes`
  # out; had the class been `[^[:alnum:]]` this vector would invent a hazard.
  expect_hazard $'Closes #173\nfoo_closes #174' 173 no
  expect_hazard $'Closes #173\n_Closes_ #174' 173 no
  # The admission bar (check a) resolves the underscore form too — pinned beside
  # the hazard vectors so the two halves cannot silently drift apart again.
  expect_ref '_Closes #173_' "$GH_REPO#173"
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
  expect_hazard '```Closes #173```' 173 no
  expect_note '```Closes #173```' 173 yes
  # ...and the mirror image stripping got wrong: a live closure AFTER such a line
  # is live too.
  expect_hazard $'Closes #173\n\n```Closes #999```\nCloses #174' 173 yes
  # N4 (verifier, this PR) — a fence-looking line inside an HTML comment is never
  # a fence, so the closure after the comment is live.
  expect_hazard $'Closes #173\n\n<!--\n```\n-->\nCloses #174' 173 yes
  # P1 (verifier, this PR) — H2 must see every reference FORM parse_issue_ref
  # accepts, not just bare #N: a backticked URL is just as disarmed.
  expect_hazard '`Closes https://github.com/daniel-ospina/agent-infra/issues/173`' 173 no
  expect_note '`Closes https://github.com/daniel-ospina/agent-infra/issues/173`' 173 yes
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
  # These are the RED-if-broken assertions for check (a)'s TWO-class
  # resolution. If parse_issue_ref ever matched "Refs/Part of/...", the closing
  # form could no longer be told from the traceability one — and closure, which
  # only the closing form implies on merge, would be inferred from a keyword
  # that never closes anything (#1630).
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

  # ── #720 + #786 + #1630: the artifact class + combined resolution ────────
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
  # fails closed — if the class were widened too far, a code-bearing diff would
  # be misreported as an artifact-only one (and, before #1630, could have dodged
  # closure with a bare "Refs #N").
  expect_artifact_only 'instruction-layer + code' $'modified\tAGENTS.md\t\nmodified\tscripts/z.sh\t' false
  expect_artifact_only 'skills non-.md (skill payload)' $'modified\tskills/foo/run.sh\t' false
  expect_artifact_only 'nested AGENTS.md is NOT the instruction layer' $'modified\tsub/AGENTS.md\t' false
  # #1409 — templates/**/*.md joins the instruction-layer class. Two live
  # instances before this: #1400 reached MERGED only by taking the false close,
  # and #1461 sat red 11 days on check (a) alone (checks b–e are SKIPPED when
  # (a) fails, so its substantive artifacts were never examined). BOTH are the
  # TWIN shape below — `AGENTS.md` + `templates/AGENTS.base.md` — because the
  # base⊆AGENTS.md pin forces the second file.
  # NOTE: this makes the CLASS reachable for such PRs; it does NOT by itself turn
  # any of them green. #1461's body carries no line-leading `Refs`/`Closes`
  # reference at all, so it stays red on (a) until one is added.
  expect_artifact_only 'templates/AGENTS.base.md alone (single-file shape)' $'modified\ttemplates/AGENTS.base.md\t' true
  expect_artifact_only 'the MANDATORY twin edit — the #1400/#1461 shape' $'modified\tAGENTS.md\t\nmodified\ttemplates/AGENTS.base.md\t' true
  expect_artifact_only 'nested templates .md' $'modified\ttemplates/.github/workflows/README.md\t' true
  # ...and the `.md` restriction is what keeps the class narrow. Measured on
  # main 2026-10-06: 18 of the 21 tracked files under templates/ are executable.
  # Every one of these reads `true` if the entry is widened to `templates/`.
  expect_artifact_only 'templates executable workflow (NOT .md)' $'modified\ttemplates/.github/workflows/pipeline-compliance.yml\t' false
  expect_artifact_only 'templates husky hook (NOT .md)' $'modified\ttemplates/.husky/pre-commit\t' false
  expect_artifact_only 'templates launchd plist (NOT .md)' $'modified\ttemplates/launchd/com.tortoise.worktree-reaper.plist\t' false
  expect_artifact_only 'templates .gitignore (NOT .md)' $'modified\ttemplates/.gitignore\t' false
  # The `$` end-anchor is what makes the `.md` restriction NARROW rather than
  # notational, and nothing pinned it: dropping only the trailing `$` leaves all
  # 203 fixtures green while `templates/x.md/evil.sh` — a SCRIPT inside a
  # directory whose name merely ends in `.md` — reads artifact-only. That is a
  # fail-open, so the anchor gets its own pin. The `skills/` entry is included
  # because it is unpinned in exactly the same way and predates this change.
  expect_artifact_only 'templates .md-named DIRECTORY is not the class (end-anchor)' $'modified\ttemplates/x.md/evil.sh\t' false
  expect_artifact_only 'skills .md-named DIRECTORY is not the class (end-anchor)' $'modified\tskills/x.md/run.sh\t' false
  # Anti-vacuous: the twin edit buys no immunity for a code path beside it.
  expect_artifact_only 'twin edit + code' $'modified\ttemplates/AGENTS.base.md\t\nmodified\tscripts/z.sh\t' false
  # The `^templates/` anchor, pinned — `templates/` is a DIRECTORY PREFIX, so
  # adjacency is a real bypass shape for a new entry and must not match.
  expect_artifact_only 'templates-adjacent path is not the templates class' $'modified\ttemplates-adjacent/AGENTS.base.md\t' false
  expect_artifact_only 'templatesX prefix is not the templates class' $'modified\ttemplatesx/AGENTS.base.md\t' false
  # (F3, cycle 3) The two members the new name/fragment binding could RELAX
  # without reddening anything: `docs/` losing its slash, and `AGENTS\\.md$`
  # losing its end anchor. Both are prefix/suffix bypasses with no other vector
  # covering them, and the new guard cannot see a LOOSER fragment (its probe is
  # one-directional: name -> fragment accepts). Falsified: with `docs/` -> `docs`
  # the whole suite stayed green and `docsite/deploy.sh` became artifact-only.
  expect_artifact_only 'docs prefix adjacency is not the docs class' $'modified\tdocsite/deploy.sh\t' false
  expect_artifact_only 'AGENTS.md with a suffix is not the exact artifact' $'modified\tAGENTS.md.bak\t' false
  # End anchors carry the same weight as prefixes: `AGENTS\\.md$` must not accept
  # a name that merely STARTS that way, or a stray backup joins the class.
  # A rename carries BOTH ends through this predicate: moving executable content
  # OUT of code and INTO a `templates/*.md` name must still read NOT
  # artifact-only, or the entry becomes an exfiltration route for a code diff.
  expect_artifact_only 'renamed code to templates .md (old end wins)' $'renamed\ttemplates/x.md\tscripts/x.sh' false
  expect_artifact_only 'renamed templates .md inside templates' $'renamed\ttemplates/b.md\ttemplates/a.md' true
  # #786's headline case: `.github/CODEOWNERS` is review-routing config with no
  # executable logic — the same artifact class (the live #674 diff is CODEOWNERS
  # + docs/). Only that exact path is in the class; a workflow file next to it,
  # or a CODEOWNERS-prefixed sibling, is NOT.
  expect_artifact_only '.github/CODEOWNERS only (the #674 case)' $'modified\t.github/CODEOWNERS\t' true
  expect_artifact_only 'CODEOWNERS + docs (the live #674 diff)' $'modified\t.github/CODEOWNERS\t\nmodified\tdocs/ops/guarded-paths.md\t\nadded\tdocs/plans/x.md\t' true
  expect_artifact_only 'CODEOWNERS + workflow (still code)' $'modified\t.github/CODEOWNERS\t\nmodified\t.github/workflows/ci.yml\t' false
  expect_artifact_only 'CODEOWNERS-adjacent path is not the exact artifact' $'modified\t.github/CODEOWNERS.d/x\t' false
  # Empty/unreadable file list must answer NOT artifact-only (fails closed).
  expect_artifact_only 'empty list' '' false
  expect_artifact_only 'status-only row' $'added' false
  # Fail-closed tripwires (VGATE #720). A filename containing a newline or tab
  # breaks the row framing; an EMPTY filename can vanish when command
  # substitution strips the trailing newline (order-dependent open); a rename
  # deletes its old path. All must read as NOT artifact-only — otherwise a code
  # diff would be misreported as an artifact-only one.
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
  # would wrongly reject a legitimate artifact-only list.
  expect_artifact_only 'unchanged status' $'unchanged\tdocs/a.md\t' true
  expect_artifact_only 'at the 3000-file API cap' "$(i=0; while [[ $i -lt 3000 ]]; do printf 'added\tdocs/f%s.md\t\n' "$i"; i=$((i+1)); done)" false
  expect_artifact_only 'just under the cap' "$(i=0; while [[ $i -lt 2999 ]]; do printf 'added\tdocs/f%s.md\t\n' "$i"; i=$((i+1)); done)" true
  # The cap counts DISTINCT paths, so a 3000-row list of 1500 delete+add pairs
  # is a complete, valid artifact-only list and must NOT be denied the class.
  expect_artifact_only '3000 rows / 1500 distinct docs paths' "$(i=0; while [[ $i -lt 1500 ]]; do printf 'removed\tdocs/f%s.md\t\nadded\tdocs/f%s.md\t\n' "$i" "$i"; i=$((i+1)); done)" true

  expect_resolve() {
    local desc="$1" body="$2" expected="$3" got
    got="$(resolve_issue_ref "$body")"
    if [[ "$got" == "$expected" ]]; then
      printf '✅ resolve_issue_ref(%s) → %q\n' "$desc" "$got"
    else
      printf '❌ resolve_issue_ref(%s) → %q (expected %q)\n' "$desc" "$got" "$expected" >&2
      selffail=$((selffail + 1))
    fi
  }
  # ── #720 / #786 / #1012 / #1630 ACCEPTANCE VECTORS ──────────────────────
  # Resolution is DIFF-AGNOSTIC since #1630, so these vectors pass the BODY
  # ONLY: the traceability form satisfies check (a) whatever the diff touches.
  # The artifact class is no longer part of this decision — it selects the PASS
  # line's wording and is pinned by expect_artifact_only above.
  # (1) a trace keyword resolves at all: the #720 behaviour, must not regress.
  expect_resolve 'Refs' 'Refs #631' "$GH_REPO#631"
  # (2) THE #1630 FIX — the trace keyword resolves where the diff is NOT an
  #     artifact. `Part of` is the partial-PR form the issue names (#1529/#1525
  #     carry `Refs #5389`); before this fix every one of these resolved to
  #     EMPTY, leaving a PARTIAL PR with no legal reference at all.
  expect_resolve 'Part of (the #1630 partial-PR case)' 'Part of #631' "$GH_REPO#631"
  expect_resolve 'Advances' 'Advances #631' "$GH_REPO#631"
  expect_resolve 'Tracks' 'Tracks #631' "$GH_REPO#631"
  expect_resolve 'Relates to' 'Relates to #631' "$GH_REPO#631"
  # (3) the closing form still WINS when both are present — #1630 widens what
  #     SATISFIES check (a); it changes nothing about what auto-closes on merge.
  expect_resolve 'closing beats trace' $'Refs #631\nCloses #701' "$GH_REPO#701"
  # (4) #1012 LIVE REGRESSION: a body that only MENTIONS a closing keyword
  #     resolves to EMPTY. This sentence is the one that satisfied check (a) on
  #     PR #968, and a mid-sentence mention can auto-close an issue on merge.
  expect_resolve 'mid-sentence closing mention' \
    'Fixing (a) is an authoring decision — a closing keyword would falsely close #949.' \
    ''
  # (5) the TRACE form is POSITIONAL too, so the widened acceptance still cannot
  #     be satisfied by prose — otherwise an issue number merely mentioned in
  #     passing would read as a reference.
  expect_resolve 'mid-sentence trace mention' \
    'This is part of a wider effort; see refs #631 for context.' \
    ''
  # (6) a normal own-line closing keyword still resolves (no regression).
  expect_resolve 'own-line Closes' $'Prose preamble that references nothing\n\nCloses #631' "$GH_REPO#631"
  expect_resolve 'no ref at all' 'nothing here' ''
  # ── #1630 END-TO-END: check (a) PASSES on a CODE diff that carries only a
  # line-leading traceability keyword. This is the defect itself, not a parser
  # unit: both vectors were RED before the fix (check (a) reported "no linked
  # issue"), because the traceability form was gated on pr_is_artifact_only.
  # The body is the truthful PARTIAL form the live PRs carry (#1529/#1525 use
  # `Refs #5389`); a closing keyword would have falsely closed an issue the PR
  # does not resolve. complexity:micro is set so b–e are exempt and the
  # assertion is about check (a) alone.
  expect_check_a_passes() {
    local desc="$1" body="$2" files="$3" log rc=0
    log="$(mktemp "${TMPDIR:-/tmp}/pipeline-1630.XXXXXX")"
    PR_BODY="$body"; LABELS="complexity:micro"; SCOPING_COMMENT=""; COMMIT_MSGS=""
    FILES="$files"; FILES_EXPECTED=""
    FAILURES=0
    run_checks >"$log" 2>&1 || rc=$?
    if grep -qF '✅ [a] linked issue' "$log"; then
      printf '✅ #1630 check (a) PASSES on a non-artifact diff: %s\n' "$desc"
    else
      printf '❌ #1630 check (a) FAILED on a non-artifact diff: %s (rc=%s) — the traceability form must not be gated on the artifact class\n' "$desc" "$rc" >&2
      grep -q '❌ \[a\]' "$log" && grep '❌ \[a\]' "$log" >&2 || true
      selffail=$((selffail + 1))
    fi
    rm -f "$log"
  }
  expect_check_a_passes 'code diff + line-leading `Refs #N` (the #1529/#1525 form)' \
    'Refs #5389' $'modified\textensions/loop-enforcer/termination.ts\t'
  expect_check_a_passes 'code diff + `Part of #N` after a blank line' \
    $'Some preamble.\n\nPart of #5389' $'modified\tscripts/z.sh\t'
  # #1630 (P1) — the traceability form must NOT suppress the closing-word
  # hazard. This half was unpinned: the only suppression vectors pinned a
  # CLOSING intended ref, so nothing exercised the invariant that a
  # traceability ref can never be the hazard scan's "intended" close-ref.
  # The shape below is a code diff whose body carries BOTH a traceability ref
  # and a closing-word mention of that SAME ref — the truthful PARTIAL form
  # from the P1 report. Before the sentinel fix this reported FAILURES=0 with a
  # green `✅ [a]` and NO hazard line, while GitHub would CLOSE #5389 on merge:
  # a false PASS whose merge performs a closure the author disclaimed.
  expect_check_a_fails() {
    local desc="$1" body="$2" files="$3" log rc=0
    log="$(mktemp "${TMPDIR:-/tmp}/pipeline-1630f.XXXXXX")"
    PR_BODY="$body"; LABELS="complexity:micro"; SCOPING_COMMENT=""; COMMIT_MSGS=""
    FILES="$files"; FILES_EXPECTED=""
    FAILURES=0
    run_checks >"$log" 2>&1 || rc=$?
    if grep -q '❌ \[a\]' "$log" && grep -q 'H1 unintended close' "$log"; then
      printf '✅ #1630 check (a) FAILS on the disclaimed-closure shape: %s\n' "$desc"
    else
      printf '❌ #1630 check (a) did NOT report the hazard: %s (rc=%s) — a traceability ref must not suppress it\n' "$desc" "$rc" >&2
      grep -q '✅ \[a\]' "$log" && grep '✅ \[a\]' "$log" >&2 || true
      selffail=$((selffail + 1))
    fi
    rm -f "$log"
  }
  expect_check_a_fails 'code diff + `Part of #N` and a closing-word mention of the SAME ref' \
    $'Part of #5389\n\n## ⚠️ This PR does NOT close #5389 — items (b)–(g) remain.' \
    $'modified\textensions/loop-enforcer/termination.ts\t'
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
  # See the `has_review_record`/#836 rationale block above. The bug was a RACE, so
  # a single run cannot pin it: every assertion below repeats REPS times and
  # requires EVERY run to agree. Pre-fix, the end-to-end half of this block was
  # RED on ~75–80 % of runs — re-running the check is what "fixed" it in CI,
  # which is exactly the flake this pins out.
  REPS=25
  # #1825 — the (c) matcher now binds a RECORD marker to a live PR identity, so
  # these vectors carry the producer's real marker rather than a phrase. The
  # identity is a fixture: offline there is no live PR, and the point of the
  # #836 vector is the SIZE of the input, not the identity behind it.
  PR_NUMBER="${PR_NUMBER:-1}"
  PR_HEAD="$(printf 'a%.0s' {1..40})"
  # The wrapper supplies the identity so assert_repeated (which passes ONE text
  # argument) still drives the PRODUCTION matcher, not a copy of it.
  has_big_review() { has_review_record "$1" "$PR_NUMBER" "$GH_REPO" "$PR_HEAD"; }
  big_filler="$(LC_ALL=C awk 'BEGIN { for (i = 0; i < 1200; i++) print "lorem ipsum dolor sit amet consectetur adipiscing elit" }')"
  # The matching token sits on the FIRST line = maximum race pressure: `grep -q`
  # matches immediately while a naive writer is still writing the remaining
  # ~64 KB of evidence text.
  big_review="review recorded: reviews/$PR_NUMBER.json verdict=clean @ $PR_HEAD ($GH_REPO)
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
  assert_repeated '#836 (c) large evidence present → present' has_big_review "$big_review" 0
  assert_repeated '#836 (e) large evidence present → present' has_test_evidence "$big_tests" 0
  assert_repeated '#836 (c) large evidence with NO marker → absent' has_big_review "$big_absent" 1
  assert_repeated '#836 (e) large evidence with NO token → absent' has_test_evidence "$big_absent" 1

  # End-to-end through the REAL run_checks — the production path the CI gate
  # takes, with a complexity:standard issue and every artifact in place except
  # a test FILE (so check (e) itself must match the >64 KB body, not the diff).
  # Pre-fix this produced 1–2 failures on most runs although nothing was missing.
  big_body="Closes #1
review recorded: reviews/$PR_NUMBER.json verdict=clean @ $PR_HEAD ($GH_REPO)
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
  # `printf`/`echo`/`grep` producers (so a `cat file | grep -q x` is a MISS; its header
  # scopes other producers out deliberately — `grep` joined the set in #864, because the
  # failure is `pipefail` plus the quiet grep early exit, not the writer identity), and looks
  # for the quiet flag
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
  # ~88% of runs at ~89 KB), misreporting a code-bearing diff as an
  # artifact-only one. (It gated check (a)'s traceability keyword until #1630;
  # now it only words the PASS line — the pin stays because the predicate must
  # answer correctly for the class it declares.) The small
  # `expect_artifact_only` vectors cannot race, so the site has its own
  # large-input behavioural pin: a >64 KB
  # row list whose FIRST row is a non-artifact path must read NOT artifact-only, on
  # EVERY run.
  # (The regex in that quote is the SHAPE AT THE TIME — `printf | grep`, before
  # the here-string rewrite, and before #1409 added `templates/.*\.md$`. It is a
  # historical quotation, deliberately NOT kept in sync with the live allowlist;
  # do not "fix" it.)
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
    printf '❌ #836 pr_is_artifact_only fail-OPEN site: %s/%s runs reported a non-artifact list as artifact-only (BROKEN-PIPE regression — the class answer is wrong)\n' \
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

  # ── #1356: the check (c) clean-low content-shape binding, and the proof that
  # it is LOAD-BEARING. The binding's vectors live in the FAIL_ALL simulation
  # (passes 6–8) deliberately: a MUTANT of this script can then run them
  # without re-entering this harness (FAIL_ALL contains none). THREE subprocess
  # runs pin the halves:
  #   * the REAL script must report "pass 6: binding fired" and "pass 8: prose
  #     mention did NOT fire" (and "pass 7: control held" when the class is
  #     sourced) — this is what puts those vectors in front of CI at all,
  #     because CI runs SELF_TEST and never FAIL_ALL (#991: a fixture nothing
  #     runs pins nothing).
  #   * a MUTANT with pr_is_clean_low_shaped neutered to `return 0` must FAIL
  #     pass 6 ("binding did NOT fire") — proving the shared shape check is the
  #     clause that refuses the marker, not decoration.
  #   * a copy of this script ALONE (no sibling producer) must refuse the same
  #     vector with the NAMED class-unreadable message — the producer-ABSENT arm
  #     (#1356 T4), which the `CLEAN_LOW_CLASS_SOURCED` branches below can only
  #     reach by accident, so it is CONSTRUCTED here rather than waited for.
  # Without the producer the class cannot be shape-EXERCISED (no pass 7, no
  # mutation) — say so LOUDLY rather than reporting a green that tested
  # nothing. Pass 6 and pass 8 still run there: both are class-independent
  # (pass 6 pins the FAIL-CLOSED refusal, pass 8 the marker-shape precision).
  #
  # Marker-shape precision, pinned directly (no subprocess): the producer's
  # CURRENT marker carries `diff=<64hex>` after the sha and `sig=<64hex>` at
  # the end (#2982), so the regex must anchor the PREFIX and not the legacy
  # end-of-marker shape — while still refusing bare prose.
  CL_SHA40="$(printf 'a%.0s' {1..40})"
  CL_MODERN="review recorded: reviews/1.json verdict=clean-low @ ${CL_SHA40} diff=$(printf 'b%.0s' {1..64}) (daniel-ospina/agent-infra) sig=$(printf 'c%.0s' {1..64})"
  CL_PROSE='code-review dispatched; the binding rejects commits claiming verdict=clean-low (marker shape only)'
  CL_MODERN_OK=no; has_clean_low_marker "$CL_MODERN" && CL_MODERN_OK=yes
  CL_PROSE_OK=yes; has_clean_low_marker "$CL_PROSE" && CL_PROSE_OK=no
  if [[ "$CL_MODERN_OK" == "yes" && "$CL_PROSE_OK" == "yes" ]]; then
    printf '✅ #1356: has_clean_low_marker accepts the modern marker (diff=/sig= carried) and ignores a prose mention\n'
  else
    printf '❌ #1356: has_clean_low_marker got the marker shape wrong (modern marker accepted=%s, prose rejected=%s) — the binding would fire on the wrong text\n' "$CL_MODERN_OK" "$CL_PROSE_OK" >&2
    selffail=$((selffail + 1))
  fi
  CL_LOG="$(mktemp "${TMPDIR:-/tmp}/pipeline-1356-real.XXXXXX")"
  CL_RC=0
  PIPELINE_COMPLIANCE_SELF_TEST=0 PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 \
    PIPELINE_COMPLIANCE_ISSUE_ONLY=0 PIPELINE_COMPLIANCE_ISSUE= PIPELINE_COMPLIANCE_SKIP=0 \
    GH_REPO="$GH_REPO" PR_NUMBER=1 bash "$SELF_SRC" >"$CL_LOG" 2>&1 || CL_RC=$?
  CL_OK=1
  grep -q 'pass 6: binding fired' "$CL_LOG" || CL_OK=0
  grep -q 'pass 8: prose mention did NOT fire' "$CL_LOG" || CL_OK=0
  if [[ "$CLEAN_LOW_CLASS_SOURCED" == "true" ]]; then
    grep -q 'pass 7: control held' "$CL_LOG" || CL_OK=0
  else
    grep -q 'pass 7 SKIPPED (producer absent' "$CL_LOG" || CL_OK=0
  fi
  if [[ "$CL_OK" == "1" ]]; then
    if [[ "$CLEAN_LOW_CLASS_SOURCED" == "true" ]]; then
      printf '✅ #1356: the FAIL_ALL clean-low vectors run against the REAL gate — pass 6 (code diff refused), pass 7 (Low diff accepted), pass 8 (prose ignored)\n'
    else
      printf '✅ #1356: with the producer absent the REAL gate still refuses a clean-low marker on a code diff (pass 6, fail-closed) and ignores a prose mention (pass 8); the shape control (pass 7) is skipped with a named reason\n'
    fi
  else
    printf '❌ #1356: the FAIL_ALL clean-low vectors did not all report clean (rc=%s) — the check (c) binding is unpinned\n' "$CL_RC" >&2
    grep -E 'pass 6|pass 7|pass 8' "$CL_LOG" >&2 || true
    selffail=$((selffail + 1))
  fi
  rm -f "$CL_LOG"

  if [[ "$CLEAN_LOW_CLASS_SOURCED" != "true" ]]; then
    printf '⏭️  #1356 mutation SKIPPED — record-review.sh is not beside this gate (%s), so the shared Low class cannot be neutered/exercised here.\n' "$RECORD_REVIEW_SH"
  else
    # The mutation. It lives in a temp dir WITH a copy of the producer, so the
    # mutant resolves the SAME shared class the real script does (a mutant whose
    # class went missing would fail closed for the WRONG reason and prove
    # nothing).
    CL_MUT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pipeline-1356-mut.XXXXXX")"
    CL_MUT="$CL_MUT_DIR/check-pipeline-compliance.sh"
    perl -0pe 's/pr_is_clean_low_shaped\(\) \{.*?\n\}/pr_is_clean_low_shaped() { return 0; }/s' "$SELF_SRC" > "$CL_MUT" || true
    cp "$RECORD_REVIEW_SH" "$CL_MUT_DIR/record-review.sh" || true
    if [[ ! -s "$CL_MUT" ]] || cmp -s "$CL_MUT" "$SELF_SRC" || ! bash -n "$CL_MUT" 2>/dev/null; then
      printf '❌ #1356 mutation: could not neuter pr_is_clean_low_shaped (reformatted?) — coverage is blind\n' >&2
      selffail=$((selffail + 1))
    else
      CL_MLOG="$CL_MUT_DIR/mutant.log"
      CL_MRC=0
      PIPELINE_COMPLIANCE_SELF_TEST=0 PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 \
        PIPELINE_COMPLIANCE_ISSUE_ONLY=0 PIPELINE_COMPLIANCE_ISSUE= PIPELINE_COMPLIANCE_SKIP=0 \
        GH_REPO="$GH_REPO" PR_NUMBER=1 bash "$CL_MUT" >"$CL_MLOG" 2>&1 || CL_MRC=$?
      if grep -q 'pass 6: binding did NOT fire' "$CL_MLOG"; then
        printf '✅ #1356 mutation is caught: with pr_is_clean_low_shaped neutered to `return 0`, the clean-low marker PASSES check (c) on the code-bearing diff — so the SHARED SHAPE CHECK is what refuses it (load-bearing)\n'
      else
        printf '❌ #1356 mutation NOT caught (mutant rc=%s) — the shape check is not what refuses the marker\n' "$CL_MRC" >&2
        grep -E 'pass 6' "$CL_MLOG" >&2 || true
        selffail=$((selffail + 1))
      fi
    fi
    rm -rf "$CL_MUT_DIR"
  fi
  # ── #1356 T4 — the PRODUCER-ABSENT arm, CONSTRUCTED rather than waited for ──
  # The absent branch above is taken only when record-review.sh happens to be
  # missing from THIS checkout — which never happens in CI: agent-infra's own
  # workflow hard-fails without the gate and always ships the producer in the
  # same repo, and the consumer template fetches record-review.sh fail-closed
  # (curl -f) before running the gate. A declared threat class whose arm is
  # reachable only by accident is pinned by nothing (#991), so this vector
  # BUILDS the absent environment: a copy of this script ALONE, no sibling
  # producer. Two runs pin the two halves, as the mutation above does:
  #   * the REAL script must refuse the code-bearing clean-low vector with the
  #     NAMED class-unreadable message (pass 6, fail-closed), skip pass 7
  #     LOUDLY, and still ignore the prose mention (pass 8) — the absent arm is
  #     a refusal, never a silent green;
  #   * a MUTANT of THAT copy with pr_is_clean_low_shaped neutered to `return 0`
  #     must report "pass 6: binding did NOT fire" — proving the fail-closed
  #     clause (not the fixture, not the marker regex) is what refuses it.
  # The fixture asserts its own premise: if a producer were reachable there, the
  # vector would silently exercise the PRESENT arm and prove nothing.
  CL_ABS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pipeline-1356-absent.XXXXXX")"
  CL_ABS="$CL_ABS_DIR/check-pipeline-compliance.sh"
  cp "$SELF_SRC" "$CL_ABS"
  if [[ -e "$CL_ABS_DIR/record-review.sh" ]]; then
    printf '❌ #1356 T4: fixture is not producer-absent (%s exists) — the vector would test the PRESENT arm\n' "$CL_ABS_DIR/record-review.sh" >&2
    selffail=$((selffail + 1))
  else
    CL_ALOG="$CL_ABS_DIR/real.log"
    CL_ARC=0
    PIPELINE_COMPLIANCE_SELF_TEST=0 PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 \
      PIPELINE_COMPLIANCE_ISSUE_ONLY=0 PIPELINE_COMPLIANCE_ISSUE= PIPELINE_COMPLIANCE_SKIP=0 \
      GH_REPO="$GH_REPO" PR_NUMBER=1 bash "$CL_ABS" >"$CL_ALOG" 2>&1 || CL_ARC=$?
    CL_AOK=1
    grep -qF 'clean-low verdict marker, but the Low content-shape class could not be read' "$CL_ALOG" || CL_AOK=0
    grep -q 'pass 6: binding fired' "$CL_ALOG" || CL_AOK=0
    grep -q 'pass 7 SKIPPED (producer absent' "$CL_ALOG" || CL_AOK=0
    grep -q 'pass 8: prose mention did NOT fire' "$CL_ALOG" || CL_AOK=0
    if [[ "$CL_AOK" == "1" ]]; then
      printf '✅ #1356 T4: with the producer CONSTRUCTED-absent, the REAL gate refuses the clean-low marker with the NAMED class-unreadable message (pass 6, fail-closed), skips pass 7 loudly, and still ignores prose (pass 8)\n'
    else
      printf '❌ #1356 T4: the producer-absent run did not report the named fail-closed refusal (rc=%s)\n' "$CL_ARC" >&2
      grep -E 'pass 6|pass 7|pass 8|could not be read' "$CL_ALOG" >&2 || true
      selffail=$((selffail + 1))
    fi
    CL_AMUT="$CL_ABS_DIR/check-pipeline-compliance.mutant.sh"
    # TWO layers refuse when the producer is absent, and BOTH must be neutered to
    # reach a false PASS: the explicit NAMED clause in check (c), and
    # pr_is_clean_low_shaped's own `CLEAN_LOW_CLASS_SOURCED == true || return 1`.
    # That layering is the point — removing one layer changes the DIAGNOSIS (the
    # remediation-bearing message) but not the verdict — so this mutant neuters
    # both, proving the fail-closed POSTURE (not one particular line) is what
    # refuses the marker. The second substitution is anchored on the refusal's
    # own message text, which is unique to check (c) (the condition text alone
    # occurs 3x in the file: the check (c) clause, its FAIL_ALL vector, and its
    # SELF_TEST arm — a bare condition-anchored pattern neutralises the wrong
    # ones).
    perl -0pe '
      s/pr_is_clean_low_shaped\(\) \{.*?\n\}/pr_is_clean_low_shaped() { return 0; }/s;
      s/if \[\[ "\$CLEAN_LOW_CLASS_SOURCED" != "true" \]\]; then\n(\s*)fail c "clean-low verdict marker, but the Low content-shape class could not be read/if false; then\n${1}fail c "clean-low verdict marker, but the Low content-shape class could not be read/s;
    ' "$SELF_SRC" > "$CL_AMUT" || true
    if [[ ! -s "$CL_AMUT" ]] || cmp -s "$CL_AMUT" "$SELF_SRC" || ! bash -n "$CL_AMUT" 2>/dev/null \
       || ! grep -q 'if false; then' "$CL_AMUT" || ! grep -q 'pr_is_clean_low_shaped() { return 0; }' "$CL_AMUT"; then
      printf '❌ #1356 T4 mutation: could not neuter BOTH fail-closed layers in the absent fixture (reformatted?) — coverage is blind\n' >&2
      selffail=$((selffail + 1))
    else
      CL_AMLOG="$CL_ABS_DIR/mutant.log"
      CL_AMRC=0
      PIPELINE_COMPLIANCE_SELF_TEST=0 PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 \
        PIPELINE_COMPLIANCE_ISSUE_ONLY=0 PIPELINE_COMPLIANCE_ISSUE= PIPELINE_COMPLIANCE_SKIP=0 \
        GH_REPO="$GH_REPO" PR_NUMBER=1 bash "$CL_AMUT" >"$CL_AMLOG" 2>&1 || CL_AMRC=$?
      if grep -q 'pass 6: binding did NOT fire' "$CL_AMLOG"; then
        printf '✅ #1356 T4 mutation is caught: with BOTH fail-closed layers neutered in the producer-ABSENT copy, the clean-low marker PASSES check (c) — so the fail-closed posture is load-bearing, and the named class-unreadable message is what layer 1 uniquely provides\n'
      else
        printf '❌ #1356 T4 mutation NOT caught (mutant rc=%s) — the absent arm is not what refuses the marker\n' "$CL_AMRC" >&2
        grep -E 'pass 6' "$CL_AMLOG" >&2 || true
        selffail=$((selffail + 1))
      fi
    fi
    rm -rf "$CL_ABS_DIR"
  fi

  # ── #1356 T7 — the `source` must not REBIND this gate's own parser constants ──
  # record-review.sh declares REFCTX/CLOSING_KW/CLOSING_KW_BOUNDARY too, and it is
  # sourced AFTER this file declares them, so the producer's values would win.
  # §8.13 pins the two copies byte-identical IN AGENT-INFRA — which is exactly why
  # the defect is invisible here and LIVE in a consumer repo that ships the
  # producer without that test (WIRING OPTION 1 copies the two files, not the
  # test): a producer from another revision would silently rebind check (a)'s
  # parser and the close-hazard scan. So assert the INVARIANT — the LIVE value
  # equals THIS FILE's own declared line — rather than the producer's agreement,
  # which the restore deliberately no longer depends on.
  CL_C7_BAD=0
  for CL_C7_C in REFCTX CLOSING_KW CLOSING_KW_BOUNDARY; do
    CL_C7_OWN="$(grep -m1 "^${CL_C7_C}=" "$SELF_SRC" | sed -e "s/^${CL_C7_C}=//" -e "s/^'//" -e "s/'$//")"
    if [[ -z "$CL_C7_OWN" || "${!CL_C7_C}" != "$CL_C7_OWN" ]]; then
      printf "❌ #1356 T7: the sourced producer REBOUND this gate's own %s — the live value no longer matches this file's declaration, so a consumer repo without §8.13 parses check (a) and the close-hazard scan with a sibling's rule\n" "$CL_C7_C" >&2
      CL_C7_BAD=$((CL_C7_BAD + 1))
    fi
  done
  if [[ "$CL_C7_BAD" == "0" ]]; then
    printf "✅ #1356 T7: the sourced producer did NOT rebind this gate's own REFCTX/CLOSING_KW/CLOSING_KW_BOUNDARY — the live values still match this file's declarations\n"
  else
    selffail=$((selffail + CL_C7_BAD))
  fi
  unset CL_C7_C CL_C7_OWN CL_C7_BAD 2>/dev/null || true

  unset CL_SHA40 CL_MODERN CL_PROSE CL_MODERN_OK CL_PROSE_OK CL_LOG CL_RC CL_OK CL_MUT_DIR CL_MUT CL_MLOG CL_MRC \
    CL_ABS_DIR CL_ABS CL_ALOG CL_ARC CL_AOK CL_AMUT CL_AMLOG CL_AMRC 2>/dev/null || true

  # ── #1224 — the RECORD-FIRST source, and the two mutations that must flip it ──
  # check (c) read its attestation from ONE place: the PR body, which any
  # `gh pr edit` overwrites (a typo fix did exactly that on agent-infra#1209 and
  # premise-labs#3788). It now reads the head-bound RECORD FILE first and the
  # body only as a fallback. THREE runs pin it, because a suite that only proved
  # the happy path would let a fail-open land green:
  #   * the REAL gate must report passes 1224a–1224f clean (record-first works; the
  #     stale record is refused with both shas; the body fallback still serves; a
  #     marker in a PR COMMENT reaches a box with no record store; an unsigned
  #     record and a present-but-unusable record are both REFUSED by name) — this
  #     is what puts those vectors in front of CI at all, since CI runs SELF_TEST
  #     and never FAIL_ALL (#991).
  #   * MUTANT A deletes the JSON read (`review_record_at_head() { return 1; }`)
  #     and must FLIP pass 1224a — while 1224c stays green, which is what makes
  #     the mutation specific to the record read rather than to check (c) as a
  #     whole.
  #   * MUTANT B drops the head comparison (its `if [ "$sha" != "$head" ]; then`
  #     becomes `if false; then`) and must FLIP pass 1224b — while 1224a and 1224c
  #     stay green. That arm is the whole point of the fix: with it gone a record
  #     for an OLDER head certifies an UNREVIEWED revision.
  #   * MUTANT C drops the SIGNATURE arm (its `sig=` block is replaced by `:`) and
  #     must FLIP pass 1224e — while 1224a stays green. Without it, a hand-written
  #     file at the store path satisfies (c) and leaves nothing in the PR to audit.
  #   * MUTANT D drops the comment arm's AUTHOR admission (the association test
  #     becomes `if false; then`) and must FLIP pass 1224h — while 1224d (a
  #     trusted author) stays green. Without it, any GitHub account can post the
  #     marker on a public repo and satisfy the ONLY required check.
  #   * MUTANT E drops the comment arm's SIGNATURE check (its verdict test becomes
  #     `if true; then`) and must FLIP pass 1224g — while 1224d stays green.
  #     Without it, an UNSIGNED comment line is evidence wherever a gate key is
  #     present to have proven otherwise.
  RV1224_DIR="$(mktemp -d "${TMPDIR:-/tmp}/pipeline-1224-mut.XXXXXX")"
  rv1224_drive() { # rv1224_drive <script> <log> — FAIL_ALL, isolated $HOME, rc on stdout
    local s="$1" log="$2" rc=0
    mkdir -p "$RV1224_DIR/home"
    HOME="$RV1224_DIR/home" \
    PIPELINE_COMPLIANCE_SELF_TEST=0 PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 \
      PIPELINE_COMPLIANCE_ISSUE_ONLY=0 PIPELINE_COMPLIANCE_ISSUE= PIPELINE_COMPLIANCE_SKIP=0 \
      GH_REPO="$GH_REPO" PR_NUMBER=1 bash "$s" >"$log" 2>&1 || rc=$?
    printf '%s' "$rc"
  }
  RV1224_RC="$(rv1224_drive "$SELF_SRC" "$RV1224_DIR/real.log")"
  RV1224_BAD=0
  for RV1224_P in 1224T 1224a 1224b 1224c 1224d 1224e 1224f 1224g 1224h 1224i 1224j; do
    grep -q "✅ pass $RV1224_P" "$RV1224_DIR/real.log" || RV1224_BAD=$((RV1224_BAD + 1))
  done
  if [[ "$RV1224_RC" == "1" && "$RV1224_BAD" == "0" ]]; then
    printf '✅ #1224: the REAL gate resolves check (c) from the head-bound SIGNED record FIRST — 1224T proves the comment fixtures are BYTE-IDENTICAL to the production fetch expression REVIEW_COMMENTS_JQ emits, 1224a passes with the body attestation WIPED (source=record), 1224b REFUSES a record bound to another head naming both shas, 1224c still accepts the body fallback, 1224d accepts the producer marker COMMENT, signed, inside the fetch frame (association + 0x1e) on a box with NO record store (the CI runner, finding 2), 1224e REFUSES an unverifiable sig as not-evidence (finding 3), 1224f reports a present-but-unusable record as UNUSABLE rather than absent (finding 4), 1224g REFUSES an UNSIGNED marker comment, 1224h REFUSES a marker comment from an author GitHub does not attest as OWNER/MEMBER/COLLABORATOR, 1224i reads the verdict from the matched LINE rather than from a stale clean-micro elsewhere in the stream, and 1224j admits a trusted-author marker where NO gate key exists (the required check runner) while saying so\n'
  else
    printf '❌ #1224: the record-first read is unpinned or wrong (rc=%s, %s of 11 vectors not green) — check (c) still depends on the mutable PR body alone\n' "$RV1224_RC" "$RV1224_BAD" >&2
    grep -E 'pass 1224|❌ \[c\]' "$RV1224_DIR/real.log" >&2 || true
    selffail=$((selffail + 1))
  fi
  # MUTANT A — the JSON read deleted. Nothing else touched, so the body fallback
  # must survive: 1224c green is the control that proves what was removed.
  RV1224_MA="$RV1224_DIR/mutantA.sh"
  perl -0pe 's/\Qreview_record_at_head()\E \{.*?\n\}/review_record_at_head() { return 1; }/s' "$SELF_SRC" > "$RV1224_MA" || true
  if [[ ! -s "$RV1224_MA" ]] || cmp -s "$RV1224_MA" "$SELF_SRC" || ! bash -n "$RV1224_MA" 2>/dev/null; then
    printf '❌ #1224 mutation A: could not delete the record read (review_record_at_head reformatted?) — the mutation guard is blind\n' >&2
    selffail=$((selffail + 1))
  else
    RV1224_ARC="$(rv1224_drive "$RV1224_MA" "$RV1224_DIR/mutA.log")"
    if grep -q '❌ pass 1224a' "$RV1224_DIR/mutA.log" && grep -q '✅ pass 1224c' "$RV1224_DIR/mutA.log"; then
      printf '✅ #1224 mutation A is caught: with the JSON record read DELETED, 1224a flips to red ("❌ pass 1224a: the on-disk record at THIS head did NOT satisfy check (c)") while the body fallback 1224c stays green — the record read is load-bearing, and only it\n'
    else
      printf '❌ #1224 mutation A NOT caught (mutant rc=%s) — deleting the record read does not redden 1224a, so the vector proves nothing\n' "$RV1224_ARC" >&2
      grep -E 'pass 1224' "$RV1224_DIR/mutA.log" >&2 || true
      selffail=$((selffail + 1))
    fi
  fi
  # MUTANT B — the head comparison dropped: the fix's whole point.
  RV1224_MB="$RV1224_DIR/mutantB.sh"
  # ⛔ EXPLICIT ESCAPING, not \Q...\E: `\Q` quotemeta runs AFTER variable
  # interpolation in a Perl regex, so \Q"$sha"\E compiles to `""` and silently
  # matches nothing — the mutation would report itself blind (measured here).
  # The guard is its own `if` statement (not a `|| continue` one-liner) so this
  # regex stays anchored on a stable, uniquely-indented line.
  perl -0pe 's/\n  if \[ "\$sha" != "\$head" \]; then/\n  if false; then # mutantB/' "$SELF_SRC" > "$RV1224_MB" || true
  if [[ ! -s "$RV1224_MB" ]] || cmp -s "$RV1224_MB" "$SELF_SRC" || ! bash -n "$RV1224_MB" 2>/dev/null \
     || ! grep -q 'if false; then # mutantB' "$RV1224_MB"; then
    printf '❌ #1224 mutation B: could not drop the head comparison ([ "$sha" != "$head" ] guard reformatted?) — the mutation guard is blind\n' >&2
    selffail=$((selffail + 1))
  else
    RV1224_BRC="$(rv1224_drive "$RV1224_MB" "$RV1224_DIR/mutB.log")"
    if grep -q '❌ pass 1224b' "$RV1224_DIR/mutB.log" && grep -q '✅ pass 1224a' "$RV1224_DIR/mutB.log"; then
      printf '✅ #1224 mutation B is caught: with the head comparison DROPPED, 1224b flips to red ("❌ pass 1224b: a record bound to ANOTHER head was ACCEPTED…") while 1224a stays green — the head binding is what refuses a stale record, not the record'\''s presence\n'
    else
      printf '❌ #1224 mutation B NOT caught (mutant rc=%s) — dropping the head comparison does not redden 1224b, so a stale record would certify an unreviewed head\n' "$RV1224_BRC" >&2
      grep -E 'pass 1224' "$RV1224_DIR/mutB.log" >&2 || true
      selffail=$((selffail + 1))
    fi
  fi
  # MUTANT C — the SIGNATURE arm neutralised: 1224e must flip, 1224a must stay green.
  # It is neutered at its COMPARISON rather than by deleting the block: a one-line
  # anchor stays stable, and the no-`sig`/shape arms still run, so what flips is
  # exactly "the HMAC decides", not "the field exists".
  RV1224_MC="$RV1224_DIR/mutantC.sh"
  perl -0pe 's/\n  if \[ "\$expect" != "\$sig" \]; then/\n  if false; then # mutantC/' "$SELF_SRC" > "$RV1224_MC" || true
  if [[ ! -s "$RV1224_MC" ]] || cmp -s "$RV1224_MC" "$SELF_SRC" || ! bash -n "$RV1224_MC" 2>/dev/null; then
    printf '❌ #1224 mutation C: could not neuter the signature comparison (review_record_eval reformatted?) — the mutation guard is blind\n' >&2
    selffail=$((selffail + 1))
  else
    RV1224_CRC="$(rv1224_drive "$RV1224_MC" "$RV1224_DIR/mutC.log")"
    if grep -q '❌ pass 1224e' "$RV1224_DIR/mutC.log" && grep -q '✅ pass 1224a' "$RV1224_DIR/mutC.log"; then
      printf '✅ #1224 mutation C is caught: with the SIGNATURE arm removed, 1224e flips to red (an unverifiable-sig record is ACCEPTED) while 1224a stays green — the signature, not the file'\''s presence, is what makes a private record evidence\n'
    else
      printf '❌ #1224 mutation C NOT caught (mutant rc=%s) — deleting the signature arm does not redden 1224e, so any hand-written file at the store path would satisfy (c)\n' "$RV1224_CRC" >&2
      grep -E 'pass 1224' "$RV1224_DIR/mutC.log" >&2 || true
      selffail=$((selffail + 1))
    fi
  fi
  # MUTANT D — the comment arm's AUTHOR admission removed: 1224h must flip.
  # 1224d (a trusted author) stays green, which is what makes the mutation
  # specific to the ASSOCIATION test and not to the comment arm as a whole.
  RV1224_MD="$RV1224_DIR/mutantD.sh"
  perl -0pe 's/\n    if ! \[\[ "\$assoc" =~ \$REVIEW_COMMENT_TRUSTED_ASSOC_RE \]\]; then/\n    if false; then # mutantD/' "$SELF_SRC" > "$RV1224_MD" || true
  if [[ ! -s "$RV1224_MD" ]] || cmp -s "$RV1224_MD" "$SELF_SRC" || ! bash -n "$RV1224_MD" 2>/dev/null \
     || ! grep -q 'if false; then # mutantD' "$RV1224_MD"; then
    printf '❌ #1224 mutation D: could not drop the comment AUTHOR admission (%s reformatted?) — the mutation guard is blind\n' 'REVIEW_COMMENT_TRUSTED_ASSOC_RE' >&2
    selffail=$((selffail + 1))
  else
    RV1224_DRC="$(rv1224_drive "$RV1224_MD" "$RV1224_DIR/mutD.log")"
    if grep -q '❌ pass 1224h' "$RV1224_DIR/mutD.log" && grep -q '✅ pass 1224d' "$RV1224_DIR/mutD.log"; then
      printf '✅ #1224 mutation D is caught: with the comment AUTHOR admission dropped, 1224h flips to red (a NONE-association commenter is ACCEPTED) while 1224d stays green — the author, not the marker text, is what admits a comment on a public repo\n'
    else
      printf '❌ #1224 mutation D NOT caught (mutant rc=%s) — dropping the author admission does not redden 1224h, so any GitHub account could satisfy check (c)\n' "$RV1224_DRC" >&2
      grep -E 'pass 1224' "$RV1224_DIR/mutD.log" >&2 || true
      selffail=$((selffail + 1))
    fi
  fi
  # MUTANT E — the comment arm's SIGNATURE check removed: 1224g must flip while
  # 1224d (correctly signed) stays green.
  RV1224_ME="$RV1224_DIR/mutantE.sh"
  perl -0pe 's/\n      if review_marker_sig_ok "\$body" "\$key"; then/\n      if true; then # mutantE/' "$SELF_SRC" > "$RV1224_ME" || true
  if [[ ! -s "$RV1224_ME" ]] || cmp -s "$RV1224_ME" "$SELF_SRC" || ! bash -n "$RV1224_ME" 2>/dev/null \
     || ! grep -q 'if true; then # mutantE' "$RV1224_ME"; then
    printf '❌ #1224 mutation E: could not neuter the comment SIGNATURE check (review_marker_sig_ok call reformatted?) — the mutation guard is blind\n' >&2
    selffail=$((selffail + 1))
  else
    RV1224_ERC="$(rv1224_drive "$RV1224_ME" "$RV1224_DIR/mutE.log")"
    if grep -q '❌ pass 1224g' "$RV1224_DIR/mutE.log" && grep -q '✅ pass 1224d' "$RV1224_DIR/mutE.log"; then
      printf '✅ #1224 mutation E is caught: with the comment SIGNATURE check removed, 1224g flips to red (an UNSIGNED marker comment is ACCEPTED where a gate key exists to have refused it) while 1224d stays green — the sig, not the text shape, is what binds a comment to the gate\n'
    else
      printf '❌ #1224 mutation E NOT caught (mutant rc=%s) — neutering the comment signature check does not redden 1224g, so a typed (unsigned) comment line could satisfy (c)\n' "$RV1224_ERC" >&2
      grep -E 'pass 1224' "$RV1224_DIR/mutE.log" >&2 || true
      selffail=$((selffail + 1))
    fi
  fi
  rm -rf "$RV1224_DIR"

  # ── #1825 — check (c)'s evidence is a HEAD-BOUND RECORD, not a phrase ──────
  # The issue's measured defect: (c) was a substring alternation over the PR
  # body and the commit messages, so a PR merged with no reviewer behind it as
  # long as one of six words appeared (PR #1822 flipped ❌→✅ on the same body
  # and the same head when one commit message gained the words). These vectors
  # pin the two halves of the replacement, and BOTH are RED against the pre-fix
  # code: the phrase vector passed (c) there, and the unbound-marker vectors
  # were satisfied by any marker with the right shape.
  PR_NUMBER="${PR_NUMBER:-1}"
  BOUND_HEAD="$(printf 'a%.0s' {1..40})"
  OTHER_HEAD="$(printf 'b%.0s' {1..40})"
  bound_marker() { # bound_marker <verdict> [head] [repo] [pr]
    printf 'review recorded: reviews/%s.json verdict=%s @ %s (%s)' \
      "${4:-$PR_NUMBER}" "$1" "${2:-$BOUND_HEAD}" "${3:-$GH_REPO}"
  }
  expect_record() { # expect_record <label> <text> <want present|absent> [pr] [head] [repo]
    # `${x-DEFAULT}` (unset-only), NOT `${x:-DEFAULT}`: the empty-head vector must be able
    # to PASS an empty head, which `:-` would silently replace with the fixture head.
    local label="$1" text="$2" want="$3" pr="${4-$PR_NUMBER}" head="${5-$BOUND_HEAD}" repo="${6-$GH_REPO}" got
    if has_review_record "$text" "$pr" "$repo" "$head"; then got=present; else got=absent; fi
    if [[ "$got" == "$want" ]]; then
      printf '✅ #1825 has_review_record(%q) → %s\n' "$label" "$got"
    else
      printf '❌ #1825 has_review_record(%q) → want %s, got %s\n' "$label" "$want" "$got" >&2
      selffail=$((selffail + 1))
    fi
  }
  # THE FAIL-OPEN ITSELF: every phrase the old matcher accepted, and nothing
  # else. Pre-fix, ALL SIX satisfied (c); post-fix none may.
  expect_record 'all six legacy phrases, no record' \
    'code-review dispatched; reviewer ran; [review]; VGATE; review recorded; review-enforcer' absent
  expect_record 'the PR #1822 shape (a commit message naming a dispatch marker)' \
    'review recorded: code-review dispatch marker for the pipeline-compliance gate [c];' absent
  # THE ARTIFACT: the producer's marker, bound to this PR, this repo, this head.
  expect_record 'the bound marker' "$(bound_marker clean)" present
  # ...and the SAME marker is NOT evidence for anything else. Each vector
  # mutates exactly one bound field, so a binding that quietly dropped a
  # comparison leaves one of them green.
  expect_record 'the bound marker, a different PR' "$(bound_marker clean '' '' "$((PR_NUMBER + 1))")" absent
  expect_record 'the bound marker, a different repo' "$(bound_marker clean '' 'daniel-ospina/tortoise')" absent
  # `@ <stale sha>` is the stale-evidence fail-open the head binding removes: a
  # review of an OLDER revision stops counting the moment the head moves.
  expect_record 'the bound marker, recorded at an EARLIER head' "$(bound_marker clean "$OTHER_HEAD")" absent
  # Repo identity is case-insensitive on GitHub, so a capitalised record still
  # binds (the same host/owner casing rule check (a) applies).
  expect_record 'the bound marker, capitalised repo' \
    "$(bound_marker clean '' "$(printf '%s' "$GH_REPO" | tr 'a-z' 'A-Z')")" present
  # WHOLE-LINE, not substring: a body that QUOTES the shape in a sentence is
  # describing the contract, not attesting to it (the #513 "this PR's own
  # description tripped the bare grep" class).
  expect_record 'the marker quoted mid-sentence' \
    "The gate wants: $(bound_marker clean) — and nothing else." absent
  # An EMPTY identity can never bind: without a PR number, a head or a repo
  # there is nothing to compare, and that must be absent, never "close enough".
  expect_record 'an empty head' "$(bound_marker clean)" absent "$PR_NUMBER" '' "$GH_REPO"
  # The optional `diff=`/`sig=` fields stay OPTIONAL: the producer's current
  # marker carries both and its older records carry neither, so requiring them
  # would silently stop reading every legacy record.
  expect_record 'the modern marker shape (diff= and sig=)' \
    "review recorded: reviews/$PR_NUMBER.json verdict=clean @ $BOUND_HEAD diff=$(printf 'c%.0s' {1..64}) ($GH_REPO) sig=$(printf 'd%.0s' {1..64})" present
  # A verdict the producer does not mint is not a record either — the shape is
  # the producer's, not "any word after verdict=".
  expect_record 'an invented verdict' "$(bound_marker approve)" absent

  # The FAIL_ALL simulation is the PRODUCTION path for check (c)'s fixtures, and
  # CI runs SELF_TEST (never FAIL_ALL) — so the passes that carry the #1825
  # vectors are driven here or they pin nothing (#991).
  B1825_LOG="$(mktemp "${TMPDIR:-/tmp}/pipeline-1825-real.XXXXXX")"
  B1825_RC=0
  PIPELINE_COMPLIANCE_SELF_TEST=0 PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 \
    PIPELINE_COMPLIANCE_ISSUE_ONLY=0 PIPELINE_COMPLIANCE_ISSUE= PIPELINE_COMPLIANCE_SKIP=0 \
    GH_REPO="$GH_REPO" PR_NUMBER=1 bash "$SELF_SRC" >"$B1825_LOG" 2>&1 || B1825_RC=$?
  B1825_OK=1
  grep -q 'pass 9: the phrase did NOT satisfy' "$B1825_LOG" || B1825_OK=0
  grep -q 'pass 10: control held' "$B1825_LOG" || B1825_OK=0
  grep -q 'another PR number: refused' "$B1825_LOG" || B1825_OK=0
  grep -q 'another repo: refused' "$B1825_LOG" || B1825_OK=0
  grep -q 'an earlier head: refused' "$B1825_LOG" || B1825_OK=0
  grep -q 'legacy marker shape (no diff=/sig=) is accepted' "$B1825_LOG" || B1825_OK=0
  if [[ "$B1825_OK" == "1" ]]; then
    printf '✅ #1825: the FAIL_ALL vectors run against the REAL gate — a phrase is refused (pass 9), the bound record is accepted (pass 10), and all three identity fields are compared (passes 11–14)\n'
  else
    printf '❌ #1825: the FAIL_ALL check-(c) vectors did not all report clean (rc=%s) — the binding is unpinned\n' "$B1825_RC" >&2
    grep -E 'pass 9|pass 10|another PR number|another repo|an earlier head|legacy marker shape' "$B1825_LOG" >&2 || true
    selffail=$((selffail + 1))
  fi
  rm -f "$B1825_LOG"

  # The SHAPE is the producer's, not this gate's invention: record-review.sh writes the marker
  # from a fixed literal template, and if that template changes (a field renamed, a space moved)
  # every real record stops satisfying (c) — a silent false BLOCK on the only required check.
  # There is no way to import the template (the producer builds it inline before posting), so the
  # two shipped literals are pinned HERE, in both their diff=/sig= and legacy forms.
  if [ -f "$RECORD_REVIEW_SH" ]; then
    B_SHAPE=0
    grep -qF 'MARKER="review recorded: reviews/${PR}.json verdict=${VERDICT} @ ${SHA} diff=${DIFF_HASH} (${REPO})"' "$RECORD_REVIEW_SH" && B_SHAPE=$((B_SHAPE + 1))
    grep -qF 'MARKER="review recorded: reviews/${PR}.json verdict=${VERDICT} @ ${SHA} (${REPO})"' "$RECORD_REVIEW_SH" && B_SHAPE=$((B_SHAPE + 1))
    grep -qF 'MARKER="${MARKER} sig=${SIG}"' "$RECORD_REVIEW_SH" && B_SHAPE=$((B_SHAPE + 1))
    if [ "$B_SHAPE" -eq 3 ]; then
      printf '✅ #1825: record-review.sh still writes the marker template this gate binds to (diff=/legacy/sig forms) — the producer and the consumer cannot drift silently\n'
    else
      printf '❌ #1825: record-review.sh marker template changed (%s/3 literals found) — every real record would stop satisfying check (c)\n' "$B_SHAPE" >&2
      selffail=$((selffail + 1))
    fi
    unset B_SHAPE
  else
    printf '⏭️  #1825 marker-shape pin SKIPPED — record-review.sh is not beside this gate (%s), so the producer template cannot be read here.\n' "$RECORD_REVIEW_SH"
  fi
  unset BOUND_HEAD OTHER_HEAD B1825_LOG B1825_RC B1825_OK 2>/dev/null || true

  # ── #1611: the artifact class is DECLARED ONCE, and both user-facing
  # surfaces RENDER it from the declaration. #1409 added one regex alternative
  # and left four restatements stale — two of them user-facing (the --help text
  # and the check-(a) refusal), so the gate explained a refusal with a rule it
  # had just relaxed. These three checks are what makes that un-repeatable.

  check_artifact_class_table_is_well_formed() {
    # Every check here is EXACT and non-tautological. The description half of the
    # retired guard is deliberately NOT restored: the description is a pure render
    # of the name column, so comparing the two only restates the render — that is
    # what made the guard a tautology, and the reason it could not be patched into
    # soundness (`OWNERS`, then `Markdown (AGENTS.md`, then a frame-span name).
    # These checks cover what a render CANNOT: a malformed row, a name and its
    # fragment disagreeing, and an alternation that adds matcher alternatives
    # without adding names — `cut -d'|' -f2-` preserves `|`, so alternation
    # survives rendering and only a count can see it.
    local row name frag probe bad=0 n_rows=${#ARTIFACT_CLASS_MEMBERS[@]} n_alts
    for row in "${ARTIFACT_CLASS_MEMBERS[@]}"; do
      name="${row%%|*}"; frag="${row#*|}"
      if [[ -z "$name" ]]; then
        printf '❌ a member row has an EMPTY name — its fragment would widen the class with nothing named to the user\n' >&2
        bad=$((bad + 1))
      fi
      if [[ -z "$frag" ]]; then
        printf '❌ the member %s has an EMPTY fragment — it matches nothing, so the rendered class silently drops it\n' "$name" >&2
        bad=$((bad + 1))
      fi
      if [[ "$frag" == *'|'* ]]; then
        printf '❌ the member %s has an ALTERNATION in its fragment — that adds matcher alternatives without adding a name the user is told about\n' "$name" >&2
        bad=$((bad + 1))
      fi
      # The human name is itself the glob, so a concrete path derived from it must
      # be accepted by that row's fragment. Catches one column moving alone, and a
      # name that is a substring/suffix of another.
      probe="$(sed -E 's#\*\*/#sub/#g; s#\*#x#g' <<<"$name")"
      if ! grep -qE "^${frag}" <<<"$probe"; then
        printf '❌ the member name %s and its matcher fragment %s disagree — the path derived from the NAME (%s) is not accepted by the FRAGMENT\n' "$name" "$frag" "$probe" >&2
        bad=$((bad + 1))
      fi
    done
    n_alts="$(sed -E 's/^\^\(//; s/\)$//' <<<"$ARTIFACT_CLASS_RE" | tr '|' '\n' | wc -l | tr -d ' ')"
    if [[ "$n_alts" -ne "$n_rows" ]]; then
      printf '❌ the matcher has %s alternative(s) but the member table has %s row(s) — an alternative exists that no row names\n' "$n_alts" "$n_rows" >&2
      bad=$((bad + 1))
    fi
    if [[ "$bad" -eq 0 ]]; then
      # Says only what is checked. "distinct" was here and is NOT checked (a
      # duplicate row with the same fragment is harmless and passes); claiming it
      # would be this PR's own defect — a message describing a rule the code does
      # not implement.
      printf '✅ the member table is well formed: %s row(s), each with a non-empty name and fragment in agreement, and no unmatched alternative\n' "$n_rows"
    else
      selffail=$((selffail + 1))
    fi
  }

  check_artifact_class_reaches_the_help_text() {
    # Binds the RENDERED --help text to the declaration. It is deliberately NOT
    # the guard that catches a restated copy: a one-line restatement that
    # contains the declaration verbatim (e.g. hidden inside a longer line) is
    # still a substring match here. The restatement scan in
    # check_artifact_class_reaches_every_message is what catches that; this guard
    # catches only the #1409 shape, where the prose was SPLIT differently, and a
    # lost or broken interpolation.
    local help
    help="$(usage 2>&1 || true)"
    if [[ "$help" == *"$ARTIFACT_CLASS_DESC"* ]]; then
      printf '✅ --help renders the artifact class from the declaration\n'
    else
      printf '❌ --help does not carry ARTIFACT_CLASS_DESC — a restated copy is stale, or the interpolation was lost\n' >&2
      selffail=$((selffail + 1))
    fi
  }

  check_artifact_class_reaches_every_message() {
    # The invariant is "declared ONCE": the class prose may appear in the
    # DECLARATION, in a COMMENT (which merely quotes it), and in this guard —
    # nowhere else, in any verb, in any heredoc. That is what #1409 broke: one
    # added alternative and four live restatements went stale, two user-facing.
    # Scanning for restatements (rather than counting interpolations) is what
    # makes this non-vacuous on a FIXED tree — a fixed tree has ZERO restatements
    # by construction, so a guard requiring a positive count is a permanent
    # false red (the first cut of this check was exactly that).
    #
    # Invariant (2) below keeps it from passing by DELETION: every user-facing
    # surface that names the class must still render it from the declaration.
    #
    # The prose is held in a variable so this guard's own source cannot satisfy
    # the pattern it greps for. A previous cut grepped the whole file for
    # `fail a "no linked issue.*\$ARTIFACT_CLASS_DESC`, whose own line matched it
    # unconditionally — a tautology that could never go red (falsified by
    # de-interpolating both messages and watching it pass).
    # Derived from the declaration, not a second copy of it: a literal needle
    # here would be a restatement exempted from its own scan, so rewording the
    # frame would silently disarm this guard while it still reported green. The
    # leading segment (up to the first `(`) is the part a restatement repeats.
    local prose_re="${ARTIFACT_CLASS_DESC%%(*}"
    local line bad=0
    while IFS= read -r raw; do
      # `grep -n` prefixes `NNN:`; strip it, or the comment exemption below can
      # never match (and the number leaks into the diagnostic).
      line="${raw#*:}"
      [[ "$line" =~ ^[[:space:]]*# ]] && continue          # comments may quote it
      [[ "$line" == *"$prose_re"* ]] || continue
      [[ "$line" == *ARTIFACT_CLASS_DESC=* ]] && continue   # the declaration
      [[ "$line" == *prose_re=* ]] && continue              # this guard's variable
      bad=$((bad + 1))
      printf '❌ a surface spells the class out instead of interpolating $ARTIFACT_CLASS_DESC: %s\n' "${line:0:110}" >&2
    done < <(grep -nF "$prose_re" "$SELF_SRC" || true)

    local -a surfaces=('fail a "no linked issue' 'echo "  a. LINKED ISSUE')
    local surface missing=0
    for surface in "${surfaces[@]}"; do
      if ! grep -qE "^ *${surface}.*\\\$ARTIFACT_CLASS_DESC" "$SELF_SRC"; then
        missing=$((missing + 1))
        printf '❌ the user-facing surface (%s) no longer renders the class from the declaration\n' "$surface" >&2
      fi
    done

    if [[ "$bad" -eq 0 && "$missing" -eq 0 ]]; then
      printf '✅ the class prose appears only in the declaration/comment/this guard (%s user-facing surface(s) render it)\n' "${#surfaces[@]}"
    else
      selffail=$((selffail + 1))
    fi
  }

  check_artifact_class_table_is_well_formed
  check_artifact_class_reaches_the_help_text
  check_artifact_class_reaches_every_message

  # ── #2467: the PROBE seam, pinned where CI actually runs it ─────────────────
  # `PIPELINE_COMPLIANCE_MARKER_PROBE=1` is the ONLY reason
  # `scripts/revalidate-required-check-on-issue-comment.sh` and this gate agree
  # about what a scoping artifact is: that script DELEGATES its parse here (a
  # second copy of the awk would drift) and reads the 0/1 answer. The seam had
  # NO assertion on this side — `PROBE_MODE` appeared only at its definition and
  # at its dispatch — so the parser could stop answering the caller's two values
  # while this suite stayed green.
  #
  # Every vector is a property the CALLER relies on, not a restatement of the
  # implementation:
  #   * the two answers: an artifact body → 0, a prose mention → 1;
  #   * REPO-FREE: with `GH_REPO` unset the probe still answers. The caller may
  #     run from a checkout whose remote does not resolve; probe mode must never
  #     turn that into exit 2, because the caller maps every non-0/1 to
  #     `blocked` and the re-validation would then refuse on every comment;
  #   * `PIPELINE_COMPLIANCE_SKIP=1` does NOT swallow the probe: the emergency
  #     override is read AFTER probe mode, so a skipped gate cannot make a prose
  #     mention answer 0 ("artifact"), which would re-trigger the required check
  #     on every comment that mentions the marker;
  #   * a NON-0/1 exit stays distinguishable as a TOOLING fault — a malformed
  #     `GH_REPO` exits 2, never 1 — because the caller's `2)` arm maps to
  #     `blocked` while a `1)` read would silently mean "no marker" (the
  #     fail-open that left a stale GREEN standing);
  #   * the IN-BAND record separator is stripped before the delimiter is
  #     re-appended: a body carrying a literal 0x1e must not be able to
  #     fabricate a record boundary and make its own later mention read as an
  #     artifact.
  expect_probe() {
    local label="$1" want="$2" body="$3"; shift 3
    local got=0
    # `env` applies this vector's own environment; the probe reads stdin only.
    # Declared and assigned separately so a non-zero probe status is CAPTURED
    # (the `local x=$(…)` shape would hide it behind the declaration's own
    # status — the discarded-status class this repo bans).
    printf '%s' "$body" | env "$@" PIPELINE_COMPLIANCE_MARKER_PROBE=1 bash "$SELF_SRC" >/dev/null 2>&1 || got=$?
    if [[ "$got" == "$want" ]]; then
      printf '✅ #2467 marker probe: %s → %s\n' "$label" "$got"
    else
      printf '❌ #2467 marker probe: %s → rc=%s (expected %s) — the revalidation caller reads 0/1 from this seam and maps every other value to blocked\n' "$label" "$got" "$want" >&2
      selffail=$((selffail + 1))
    fi
  }
  PROBE_ARTIFACT='<!-- issue-scoping: 2026-10-31 (standard) · #1 -->

## Scope
'
  PROBE_MENTION='We have no `<!-- issue-scoping:` comment here.
'
  expect_probe 'an artifact body' 0 "$PROBE_ARTIFACT"
  expect_probe 'a prose MENTION' 1 "$PROBE_MENTION"
  expect_probe 'an artifact body with GH_REPO unset (probe mode is repo-FREE)' 0 "$PROBE_ARTIFACT" -u GH_REPO
  expect_probe 'a prose MENTION with PIPELINE_COMPLIANCE_SKIP=1 (the override must not swallow the probe)' 1 "$PROBE_MENTION" PIPELINE_COMPLIANCE_SKIP=1
  expect_probe 'a malformed GH_REPO (a TOOLING fault: 2, never 1)' 2 "$PROBE_ARTIFACT" GH_REPO=not-a-repo
  expect_probe 'a body carrying a literal 0x1e before a forged marker (the RS is stripped)' 1 $'intro\n\036<!-- issue-scoping: forged -->\n'
  unset PROBE_ARTIFACT PROBE_MENTION 2>/dev/null || true

  # ── #2467: the PR LANE must EXECUTE the revalidation script's assertions ────
  # `scripts/revalidate-required-check-on-issue-comment.sh` ships ~40 assertions
  # (the two-probe `probe_outcome` mapping included) and was wired into CI in
  # exactly ONE place: a later step of the `revalidate-on-issue-comment` job,
  # whose `if:` is `github.event_name == 'issue_comment' && …pull_request == null`.
  # A step there never runs on a `pull_request` event, and nothing on the PR lane
  # executed the file either, so a regression in its decisions merged GREEN and
  # first ran on some later issue comment — against the default-branch head,
  # where the failure cannot be attributed to the change that caused it.
  #
  # The assertion is the INVOCATION'S ENCLOSING JOB, not the file's presence: a
  # `REVALIDATE_SELF_TEST=1` line under the comment job satisfies a grep and
  # pins nothing. Comments are skipped, so a COMMENTED-OUT invocation cannot
  # satisfy it either (the hazard the materialize-agents step names).
  reval_sh="$(cd "$(dirname "$SELF_SRC")" && pwd)/revalidate-required-check-on-issue-comment.sh"
  pipeline_repo_root="$(cd "$(dirname "$SELF_SRC")/.." && pwd)"
  pipeline_wf="$pipeline_repo_root/.github/workflows/pipeline-compliance.yml"
  # An agent-infra-ONLY signal, the same pair the workflow's own steps use (`pi-bootstrap/`
  # and `bin/agent-infra.js` are never shipped to consumers). It decides whether a missing
  # input is a FAILURE (this repo lost a file it must ship) or a SKIP (a consumer layout,
  # where the question cannot arise) — never a silent pass either way.
  if [[ -f "$pipeline_repo_root/pi-bootstrap/setup.sh" || -f "$pipeline_repo_root/bin/agent-infra.js" ]]; then
    pipeline_is_self=true
  else
    pipeline_is_self=false
  fi
  if [[ ! -f "$reval_sh" ]]; then
    if [[ "$pipeline_is_self" == "true" ]]; then
      printf '❌ #2467 wiring: this is an agent-infra checkout but %s is missing — the revalidation suite cannot be executed on the PR lane at all\n' "${reval_sh##*/}" >&2
      selffail=$((selffail + 1))
    else
      printf '⏭️  #2467 wiring SKIPPED — %s is not beside this gate (consumer checkout), so its PR-lane step cannot be judged here.\n' "${reval_sh##*/}"
    fi
  elif [[ ! -f "$pipeline_wf" ]]; then
    if [[ "$pipeline_is_self" == "true" ]]; then
      printf '❌ #2467 wiring: %s is missing from this agent-infra checkout, so the step that must run the revalidation suite on the PR lane cannot be verified at all\n' "${pipeline_wf##*/}" >&2
      selffail=$((selffail + 1))
    else
      printf '⏭️  #2467 wiring SKIPPED — %s is absent, so there is no PR-lane workflow to judge here.\n' "${pipeline_wf##*/}"
    fi
  else
    # The enclosing job is the last `^  <name>:` line before the invocation.
    reval_job="$(awk '
      /^  [A-Za-z0-9_-]+:[[:space:]]*$/ { j = $1; sub(/:$/, "", j) }
      /^[[:space:]]*#/ { next }
      index($0, "REVALIDATE_SELF_TEST=1") && index($0, "bash") { if (!seen) { print j; seen = 1 } }
    ' "$pipeline_wf")"
    if [[ "$reval_job" == "pipeline-compliance" ]]; then
      printf '✅ #2467 wiring: the `pipeline-compliance` job (the PR lane) runs `REVALIDATE_SELF_TEST=1` — the revalidation script\047s assertions execute on every PR, not only on an issue comment\n'
    elif [[ -z "$reval_job" ]]; then
      printf '❌ #2467 wiring: NO live `REVALIDATE_SELF_TEST=1` invocation in %s — the revalidation script\047s assertions are executed by nothing on the PR lane, so a regression in it merges green and first surfaces on a later issue comment (#991: a fixture nothing runs pins nothing)\n' "${pipeline_wf##*/}" >&2
      selffail=$((selffail + 1))
    else
      printf '❌ #2467 wiring: the `REVALIDATE_SELF_TEST=1` invocation sits in job `%s`, which does not run on a pull_request event — the suite is invisible to every PR (the PR lane is `pipeline-compliance`)\n' "$reval_job" >&2
      selffail=$((selffail + 1))
    fi
    unset reval_job
  fi
  unset reval_sh pipeline_repo_root pipeline_wf pipeline_is_self 2>/dev/null || true

  # Run the exit check AFTER the #1611 guards, so a failure there is reported
  # on the same run instead of masking them (this is how the unbound-variable
  # regression above stayed hidden on the first attempt).
  if [[ "$selffail" -gt 0 ]]; then
    echo "❌ SELF-TEST FAILED ($selffail assertion(s))." >&2
    exit 2
  fi

  echo "✅ SELF-TEST PASS — parse_issue_ref matches a POSITIONAL reference context only (bare #N, owner/repo#N, full URL, pull-URL exclusion; #1012); parse_trace_ref shares that context and covers the NON-closing traceability form, accepted for ANY diff since #1630; pr_is_artifact_only answers over the class declared ONCE as ARTIFACT_CLASS_RE/ARTIFACT_CLASS_DESC and fails closed on any code path, and the class's wording, its --help text and its check-(a) refusal are bound to that declaration (#1611); the check (c) clean-low binding consumes the producer's OWN Low class (sourced from record-review.sh, never restated) and is proven load-bearing by a mutation, INCLUDING in a CONSTRUCTED producer-absent copy where both fail-closed layers must be neutered to reach a false PASS, and the source is held to contributing ONLY that class — the gate's own REFCTX/CLOSING_KW/CLOSING_KW_BOUNDARY are restored, so a consumer repo without §8.13 cannot have check (a) rebound by a sibling (#1356); resolve_issue_ref prefers closure; and check (c) accepts ONLY the record-review.sh marker BOUND to this PR, this repo and this head — every legacy phrase is refused, and each identity field is proven load-bearing by its own vector (#1825); and (#1224) that evidence is resolved RECORD → COMMENT → BODY — the signed head-bound record file first, the marker in a PR COMMENT next (the copy that survives a body edit AND travels to a CI runner with no record store), the PR body/commit marker last; the source that answered is printed on every (c) line; the body-wiped red-to-green case passes from the record; a record bound to another head is REFUSED naming both shas; a record at this head whose sig= does not verify is refused as NOT evidence; a record that exists but is unusable is reported as UNUSABLE with the field that refused it, never as absent; the COMMENT arm is proven on the PRODUCTION fetch frame (author_association + the 0x1e record terminator), admits only an OWNER/MEMBER/COLLABORATOR author, refuses an unsigned marker wherever a gate key exists, still answers on the no-key runner the required check runs on, and takes its verdict from the marker LINE that matched rather than from a stale clean-micro elsewhere in the append-only stream; FIVE mutations (the record read deleted; the head comparison dropped; the record signature arm removed; the comment AUTHOR admission dropped; the comment SIGNATURE check removed) each redden exactly their own vector while the trusted-author control stays green; and the marker-probe seam that the revalidation script DELEGATES its parse to is pinned by its own vectors, with a PR-lane wiring assertion that the revalidation suite is actually executed (#2467)."
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
# #1224 — the PR COMMENTS: the copy of the review attestation that survives a
# `gh pr edit` AND reaches a CI runner (whose $HOME has no `~/.pi/agent/reviews`,
# so the record file cannot travel — see resolve_review_evidence's comment arm).
#
# The frame is `<author_association>\x1f<body>\x1e` per comment, and it is built by
# REVIEW_COMMENTS_JQ — the ONE definition, which the self-test's fixtures use too
# (a fixture that hand-builds a different shape is how the `0x1e` defect stayed
# invisible: the vector proved a value the transport never produces).
#   * the association travels IN-BAND because admission needs the AUTHOR: any
#     GitHub account can comment on a public repo, so `.[].body` alone was a
#     field writable by parties with no write access (see
#     has_comment_review_record);
#   * both delimiter bytes are stripped from every body first, so the frame
#     cannot be forged from comment content (the same rule the scoping fetch
#     states, and the reason the separator is unforgeable);
#   * the 0x1e terminator is kept (not turned into a newline) so the consumer can
#     still tell comments apart — the consumer splits on it, which is what makes
#     the producer's marker-only comment match at all.
# ⛔ A fetch failure does NOT leave this empty: `fetch_json` classifies the failure
# and exits 2, so the gate ABORTS with BLOCKED-BY-TOOLING rather than continuing
# on an empty value (the earlier wording here claimed a degradation the code does
# not perform). That is the same posture as PR_BODY and SCOPING_COMMENT, and on
# this endpoint it is the paginated read, i.e. the most failure-prone of the
# four — if the API cannot answer, no verdict is issued.
PR_COMMENTS="$(fetch_json "issues/$PR_NUMBER/comments" "$REVIEW_COMMENTS_JQ" 1)"
# The CURRENT head sha — check (c)'s binding target (#1825). Fetched BEFORE the
# checks run, and a failed read leaves it EMPTY so (c) fails closed rather than
# grading a marker against no revision at all.
PR_HEAD="$(fetch_json "pulls/$PR_NUMBER" '.head.sha // ""')"

# Files fetched as "status<TAB>filename<TAB>previous_filename" — check e needs
# the status to count only added/modified test files as evidence; checks d/e
# derive plain names; check (a)'s PASS wording needs the old path to judge
# renames (pr_is_artifact_only). Fetched before the checks that read it.
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
LIVE_ISSUE_REF="$(resolve_issue_ref "$PR_BODY")"
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
