#!/usr/bin/env bash
# revalidate-required-check-on-issue-comment.sh — re-run the repo's REQUIRED
# check when the artifact that check reads is posted on the LINKED ISSUE.
#
# ⛔ THE DEFECT THIS EXISTS FOR (measured 2026-10-31, agent-infra PR #3122).
# `pipeline-compliance` is this repo's only required status context (#646), and
# checks (b)/(d) read the LINKED ISSUE — its `<!-- issue-scoping:` comment and
# its `complexity:` labels — not the PR. Those objects live OUTSIDE the PR's
# event surface: `pipeline-compliance.yml` triggers on `pull_request`
# (opened/synchronize/reopened/edited), and posting a comment on the ISSUE
# fires NO `pull_request` event. So a red minted before the scoping comment
# existed survives after it exists, and nothing re-reads the gate.
#
# Measured, verbatim, on PR #3122 head 3be41e42:
#   run 41162232810  pull_request  attempt=1  failure   executed 03:16:06Z
#     log: "❌ [b] no scoping comment on issue #3121"
#   issue #3121 scoping comment created         03:18:15Z
#   run 41162251521  pull_request  attempt=1  success   executed 03:19:44Z
# Two runs of the SAME required check on the SAME commit therefore disagreed,
# and the disagreement was decided by queue latency (that second run had been
# queued since 02:57:30Z) — not by the PR. A reader that takes any red, or that
# takes the newest, is reading a coin flip. This is category A: the repo's one
# merge authority is non-deterministic in time.
#
# The root is tracked on #2467 ("a fully-attested PR stays red on
# pipeline-compliance because nothing re-reads the check after the record
# lands"). #2467's scoped fix is the RECORDER's re-read, which covers check (c);
# it cannot cover (b)/(d), whose writer is `issue-scoping` and which posts to
# the ISSUE. This script is that missing arm, and it changes no check, no
# verdict and no refusal class: it re-runs the SAME check over the CURRENT
# issue state, so a red that comes back stands.
#
# ⛔ IT NEVER POSTS ANYTHING ON THE ISSUE. Re-posting a scoping marker to turn a
# check green is manufacturing evidence. This script only re-reads.
#
# Usage (CI: .github/workflows/pipeline-compliance.yml, `issue_comment` job):
#   GH_REPO=owner/repo ISSUE_NUMBER=123 COMMENT_BODY="…" \
#   COMMENT_AUTHOR_ASSOCIATION=OWNER \
#     bash scripts/revalidate-required-check-on-issue-comment.sh
#
# Usage (self-test, no gh calls):
#   REVALIDATE_SELF_TEST=1 bash scripts/revalidate-required-check-on-issue-comment.sh
#
# Exit codes: 0 = nothing to do OR re-runs dispatched; 1 = usage error;
#             2 = tooling/API failure (never reported as a policy verdict).
set -uo pipefail

SELF="${BASH_SOURCE[0]}"

say() { printf '%s\n' "$*"; }
say_err() { printf '%s\n' "$*" >&2; }

# ── Pure decision: may this comment author trigger a re-run? ────────────────
# ONLY a repo-trusted author. An outside commenter can post a comment with the
# marker text on any open issue; `actions: write` on the required check must
# never be reachable from there. This is the whole reason the association is
# checked BEFORE the marker (a stranger's comment costs no parse and no API
# call beyond the one GitHub already paid for).
trusted_association() {
  case "${1:-}" in
    OWNER|MEMBER|COLLABORATOR) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Pure decision: given the newest completed attempt, re-run or not? ───────
# `rerun` only when the newest attempt is a genuine red. Anything non-red is
# left alone: re-running a green check burns a runner and can only replace a
# PASS with a later verdict, which is strictly worse. An UNKNOWN conclusion is
# treated as red — the merge rail's own polarity allow-list (@#2474), because a
# value nobody named must never fall through a gap.
rerun_decision() {
  local conclusion="${1:-}" status="${2:-completed}"
  case "$status" in
    completed) ;;
    *) printf 'skip:in-flight'; return 0 ;;
  esac
  case "$conclusion" in
    success|neutral|skipped|cancelled|stale) printf 'skip:already-non-red' ;;
    *) printf 'rerun' ;;
  esac
}

# ── Pure: open PR numbers that reference the issue, from a timeline page ────
# Reads `issues/<n>/timeline`, which is the ONLY GitHub surface that maps an
# issue to the PRs that cross-referenced it. A `cross-referenced` event whose
# source is a PR gives the PR number; closed PRs are dropped because branch
# protection does not apply to them. Prints one number per line.
linked_open_prs() {
  local api="${2:-}"
  printf '%s' "${1:-}" | jq -r --arg api "$api" '
    if type != "array" then empty else .[] end
    | select(.event == "cross-referenced")
    | .source.issue
    | select(. != null and .pull_request != null and (.state == "open"))
    | select($api == "" or ((.repository_url // "") | ascii_downcase) == ($api | ascii_downcase))
    | .number
  ' 2>/dev/null | sort -un
}

# ── Pure: is this comment a REAL scoping artifact? ──────────────────────────
# ⛔ DELEGATED, NEVER RESTATED. `has_scoping_marker` in
# check-pipeline-compliance.sh defines the position contract (first content
# line, or a blank-line-separated last line) and this file must not grow a
# second, drifting copy of it — the "two parsers disagreeing" class this gate
# has already re-learned (#991, #513). The gate exposes it through the documented
# PIPELINE_COMPLIANCE_MARKER_PROBE seam.
marker_is_artifact() {
  local body="${1:-}" rc=0
  PIPELINE_COMPLIANCE_MARKER_PROBE=1 \
    bash "${GATE_SCRIPT:?GATE_SCRIPT unset}" <<<"$body" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) return 2 ;;
  esac
}

# ── Pure: map the two probe return codes to this arm's outcome ──────────
# ⛔ THE MAPPING IS A FUNCTION SO IT CAN BE ASSERTED. It was written inline as
# `if ! marker_is_artifact "$body"; then case "$?" in 1) …` — and that is a
# SILENT INVERSION: `$?` inside the `then` block of `if ! cmd` is 0 (the
# negation's status), never the command's, so the `1)` arm was unreachable and
# every ordinary comment — a benign "nothing the gate reads has changed" — took
# the tooling branch and exited 2, reding the workflow on every comment in the
# repo. Measured: `bash -c 'f(){ return 2; }; if ! f; then echo $?; fi'` → 0.
#
# ⛔ AND IT TAKES TWO PROBES, NOT ONE, because `issue_comment: edited` is
# BIDIRECTIONAL and a one-sided read is a FAIL-OPEN. Probing only the new body
# means an edit that REMOVES the marker probes 1 → `skip` → exit 0, while the
# gate's own input was retracted and the previous GREEN stays on the head with
# nothing to re-read it (a `pull_request` event is not fired by an issue
# comment). Measured before this symmetry existed: body `'Scoping retracted —
# the marker no longer applies'` from an OWNER printed "nothing the gate reads
# has changed" and exited 0. The payload carries the prior body for free
# (`github.event.changes.body.from`), so retraction is detectable at no cost.
#   0 → proceed, 1 → skip (benign, neither body is an artifact),
#   anything else → blocked (a tooling fault is NOT a false answer: reading it as
#   "no marker" would make this arm a silent no-op gate).
# Precedence: `blocked` beats a proceed, because a probe that could not answer
# must never be laundered through the other probe's answer.
probe_outcome() {
  local new_rc="${1:-}" prev_rc="${2:-}"
  # An ABSENT body is "no artifact", not "no answer": `github.event.changes.body.from`
  # does not exist on an `issue_comment: created` event, so the replaced body is
  # empty there and must not be read as a tooling fault. (The probe itself already
  # answers 1 for empty text; this is belt-and-braces, and it is asserted.)
  [[ -z "$new_rc" ]] && new_rc=1
  [[ -z "$prev_rc" ]] && prev_rc=1
  if [[ "$new_rc" != "0" && "$new_rc" != "1" ]]; then printf 'blocked'; return 0; fi
  if [[ "$prev_rc" != "0" && "$prev_rc" != "1" ]]; then printf 'blocked'; return 0; fi
  if [[ "$new_rc" == "0" ]]; then printf 'proceed'; return 0; fi
  if [[ "$prev_rc" == "0" ]]; then printf 'retracted'; return 0; fi
  printf 'skip'
}

# ── Live path ───────────────────────────────────────────────────────────────
main() {
  local repo="${GH_REPO:-}" issue="${ISSUE_NUMBER:-}" body="${COMMENT_BODY:-}"
  local assoc="${COMMENT_AUTHOR_ASSOCIATION:-}"
  GATE_SCRIPT="${GATE_SCRIPT:-$(dirname "$SELF")/check-pipeline-compliance.sh}"

  [[ -n "$repo" && -n "$issue" ]] || {
    say_err "usage: GH_REPO=owner/repo ISSUE_NUMBER=<n> COMMENT_BODY=<text> \\"
    say_err "       COMMENT_AUTHOR_ASSOCIATION=<A> [GATE_SCRIPT=<path>] bash $SELF"
    return 1
  }
  [[ "$issue" =~ ^[0-9]+$ ]] || { say_err "ISSUE_NUMBER must be digits, got '$issue'"; return 1; }

  say "revalidate: issue $repo#$issue"

  if ! trusted_association "$assoc"; then
    say "  skip:untrusted-comment-author (association='${assoc:-none}') — only OWNER/MEMBER/COLLABORATOR may re-trigger the required check"
    return 0
  fi
  marker_is_artifact "$body"; local mrc=$?
  marker_is_artifact "${PREVIOUS_COMMENT_BODY:-}"; local prc=$?
  case "$(probe_outcome "$mrc" "$prc")" in
    proceed) say "  scoping artifact detected on the issue" ;;
    retracted) say "  scoping artifact RETRACTED by this edit (the replaced body carried the marker) — re-reading the gate so the stale green cannot stand" ;;
    skip) say "  skip:not-a-scoping-artifact — neither this comment nor the body it replaced carries '<!-- issue-scoping:' as its first content line or as a blank-line-separated footer; nothing the gate reads has changed"; return 0 ;;
    *) say_err "  BLOCKED-BY-TOOLING — a marker probe could not answer (new=$mrc, previous=$prc); that is NOT a verdict that the issue is un-scoped."; return 2 ;;
  esac

  local timeline prs api
  timeline="$(gh api "repos/$repo/issues/$issue/timeline" --paginate 2>/dev/null)" || {
    say_err "  BLOCKED-BY-TOOLING — could not read the issue timeline; NOT a policy verdict, and NOT evidence that any PR is compliant."
    return 2
  }
  api="https://api.github.com/repos/$repo"
  # Same rule as the two `gh api` reads below: a PARSER fault is not an empty
  # answer. Without this, a jq failure left `prs` empty and the run exited 0
  # reporting `skip:no-open-pr` — success having decided nothing.
  if ! prs="$(linked_open_prs "$timeline" "$api")"; then
    say_err "  BLOCKED-BY-TOOLING — could not parse the linked-PR timeline; NOT a verdict that no PR depends on this issue."
    return 2
  fi
  if [[ -z "$prs" ]]; then
    say "  skip:no-open-pr — no open PR cross-references this issue, so no required check depends on it"
    return 0
  fi

  local rc=0 pr head run_id verdict
  for pr in $prs; do
    head="$(gh api "repos/$repo/pulls/$pr" --jq '.head.sha // ""' 2>/dev/null)"
    if [[ -z "$head" ]]; then
      say "  PR #$pr  BLOCKED-BY-TOOLING — could not read the PR head"
      rc=2; continue
    fi
    # The newest Pipeline Compliance run for THIS head. A run created for an
    # older head can never carry a verdict this PR is graded on.
    if ! run_id="$(gh api "repos/$repo/actions/runs?head_sha=$head&per_page=100" \
        --jq '[.workflow_runs[] | select(.name == "Pipeline Compliance")] | sort_by(.id) | last | .id // ""' 2>/dev/null)"; then
      say "  PR #$pr  BLOCKED-BY-TOOLING — could not list runs for head $head"
      rc=2; continue
    fi
    if [[ -z "$run_id" ]]; then
      say "  PR #$pr  skip:no-run-for-head ($head) — nothing to re-read"
      continue
    fi
    if ! verdict="$(gh api "repos/$repo/actions/runs/$run_id" \
        --jq '"\(.status)/\(.conclusion // "")"' 2>/dev/null)"; then
      say "  PR #$pr  BLOCKED-BY-TOOLING — could not read run $run_id"
      rc=2; continue
    fi
    if [[ "$verdict" != */* ]]; then
      say "  PR #$pr  BLOCKED-BY-TOOLING — run $run_id returned no readable status/conclusion"
      rc=2; continue
    fi
    local decision
    decision="$(rerun_decision "${verdict##*/}" "${verdict%%/*}")"
    case "$decision" in
      rerun)
        if gh api -X POST "repos/$repo/actions/runs/$run_id/rerun" >/dev/null 2>&1; then
          say "  PR #$pr  RERUN dispatched (run $run_id, ${verdict##*/}) — the same check over the current issue state; its verdict stands either way"
        else
          say "  PR #$pr  BLOCKED-BY-TOOLING — rerun of $run_id was refused"
          rc=2
        fi
        ;;
      *) say "  PR #$pr  $decision (run $run_id, $verdict)" ;;
    esac
  done
  return "$rc"
}

# ── Self-test: the pure decisions, no gh calls at all ───────────────────────
# Deliberately asserts the DECISIONS this file owns (trust, re-run polarity,
# issue→PR mapping) and that the parser is DELEGATED — not that the CLI wiring
# works, which CI proves by running it for real.
if [[ "${REVALIDATE_SELF_TEST:-0}" == "1" ]]; then
  fails=0
  ok() { pass_n=$(( ${pass_n:-0} + 1 )); }
  bad() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails+1)); }

  for a in OWNER MEMBER COLLABORATOR; do
    trusted_association "$a" && ok || bad "trusted_association refused '$a'"
  done
  for a in NONE CONTRIBUTOR "" stranger; do
    trusted_association "$a" && bad "trusted_association admitted '$a'" || ok
  done

  [[ "$(rerun_decision failure completed)" == "rerun" ]] && ok || bad "failure must re-run"
  [[ "$(rerun_decision "" completed)" == "rerun" ]] && ok || bad "an UNKNOWN conclusion must re-run (fail-closed polarity)"
  [[ "$(rerun_decision timed_out completed)" == "rerun" ]] && ok || bad "an unnamed conclusion must re-run"
  for c in success neutral skipped cancelled stale; do
    [[ "$(rerun_decision "$c" completed)" == "skip:already-non-red" ]] && ok || bad "non-red '$c' must not re-run"
  done
  [[ "$(rerun_decision failure queued)" == "skip:in-flight" ]] && ok || bad "an in-flight run must not be re-triggered"

  # The two-probe mapping. Asserted because an INLINE one-probe version of it was
  # shipped inverted (`$?` after `if !`), and no assertion covered it.
  [[ "$(probe_outcome 0 1)" == "proceed" ]] && ok || bad "new body IS an artifact → proceed"
  [[ "$(probe_outcome 0 0)" == "proceed" ]] && ok || bad "both artifacts → proceed"
  [[ "$(probe_outcome 1 0)" == "retracted" ]] && ok || bad "marker REMOVED by an edit → retracted (never a benign skip)"
  [[ "$(probe_outcome 1 1)" == "skip" ]] && ok || bad "neither body is an artifact → benign skip"
  [[ "$(probe_outcome 2 0)" == "blocked" ]] && ok || bad "a tooling fault must beat a proceed"
  [[ "$(probe_outcome 0 2)" == "blocked" ]] && ok || bad "a tooling fault on the replaced body must beat a proceed"
  [[ "$(probe_outcome 127 1)" == "blocked" ]] && ok || bad "a missing gate script must be blocked"

  tl='[{"event":"cross-referenced","source":{"issue":{"number":11,"state":"open","repository_url":"https://api.github.com/repos/o/r","pull_request":{"url":"u"}}}},
       {"event":"cross-referenced","source":{"issue":{"number":12,"state":"closed","repository_url":"https://api.github.com/repos/o/r","pull_request":{"url":"u"}}}},
       {"event":"cross-referenced","source":{"issue":{"number":14,"state":"open","repository_url":"https://api.github.com/repos/other/repo","pull_request":{"url":"u"}}}},
       {"event":"cross-referenced","source":{"issue":{"number":13,"state":"open","repository_url":"https://api.github.com/repos/o/r"}}},
       {"event":"commented"}]'
  got="$(linked_open_prs "$tl" "https://api.github.com/repos/o/r" | tr '\n' ' ')"
  [[ "$got" == "11 " ]] && ok || bad "linked_open_prs must yield only the open PR, got '$got'"
  # A cross-referenced event from a FOREIGN repo must be dropped: the number alone
  # cannot be told from one of ours, so re-running it would grade a different PR.
  [[ "$(linked_open_prs "$tl" "https://api.github.com/repos/other/repo")" == "14" ]] && ok || bad "linked_open_prs must resolve a FOREIGN cross-reference only when asked as that repo"
  [[ -z "$(linked_open_prs 'not-json' 'https://api.github.com/repos/o/r')" ]] && ok || bad "malformed timeline must yield nothing (fail-closed, never a crash)"

  # The parser seam must exist, or this script silently degrades to "never a
  # scoping artifact" and the whole re-validation becomes a no-op gate.
  gate="${GATE_SCRIPT:-$(dirname "$SELF")/check-pipeline-compliance.sh}"
  if [[ -f "$gate" ]]; then
    GATE_SCRIPT="$gate"
    tmpd="$(mktemp -d "${TMPDIR:-/tmp}/rv.XXXXXX")" || { bad "could not create a temp dir"; tmpd=""; }
    if [[ -n "$tmpd" ]]; then
      printf '<!-- issue-scoping: 2026-10-31 (standard) · #1 -->\n\n## Scope\n' > "$tmpd/marker.txt"
      printf 'We have no `<!-- issue-scoping:` comment here.\n' > "$tmpd/mention.txt"
      marker_is_artifact "$(cat "$tmpd/marker.txt")" && ok || bad "gate probe rejected a real artifact"
      marker_is_artifact "$(cat "$tmpd/mention.txt")" && bad "gate probe admitted a prose MENTION" || ok
      # The fixtures are left in the mktemp dir deliberately: a self-test that
      # cannot RUN is a fixture nothing runs, and this file keeps no
      # destructive cleanup of any kind — two small files in a freshly made
      # temp dir cost nothing, and CI's runner is discarded anyway.
    fi
  else
    # ⛔ A MISSING GATE IS NOT A PASS. Without this branch the one assertion that
    # pins the delegation — and therefore the whole arm — could vanish while the
    # suite still printed a green count ("a fixture nothing runs pins nothing").
    bad "gate script not found at $gate — the delegated marker parser is unpinned"
  fi

  if (( fails > 0 )); then
    printf '❌ REVALIDATE SELF-TEST: %d failure(s)\n' "$fails" >&2
    exit 1
  fi
  printf '✅ REVALIDATE SELF-TEST: %d assertions passed\n' "${pass_n:-0}"
  exit 0
fi

main "$@"
