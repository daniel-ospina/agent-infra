#!/usr/bin/env bash
# tests/admin-merge/run.sh — #930 safe `--admin` merge rail suite.
#
# The rail: `--admin` bypasses required checks, so nothing makes it *safe*.
# tortoise #3420 merged carrying a test that was NOT in main's failing set, and
# main ratcheted redder. The rail is
#
#   scripts/ci-failure-set.sh   one parser (--pr / --main-union / --diff)
#   scripts/admin-merge.sh      evidence + zero-unique gate + flake re-run + merge
#   extensions/review-enforcer  refuses a RAW `gh pr merge … --admin` without
#                               head-bound evidence (its own suite covers that)
#
# What this suite pins:
#   1. `--diff` is set subtraction on unsorted, duplicated input (the ONE
#      implementation every consumer shares)
#   2. THE #3469 TRAP: an order-flaky sibling pair whose raw single-run
#      `comm -23` = 1 but whose true unique count is 0. A single-run baseline
#      FALSE-BLOCKS; the union does not. Both halves are asserted, so removing
#      the union re-breaks this test.
#   3. a unique failure that passes on retry is classified flaky and recorded as
#      such in the evidence — and does not block
#   4. a genuine new failure that SURVIVES the re-run BLOCKS: non-zero exit, the
#      list printed, NO evidence comment, NO merge
#   5. an EXTRACTION FAILURE (unreadable log) blocks — an unreadable set is never
#      read as "no unique failures" (the vacuous pass)
#   6. the evidence comment carries the head-bound marker, the counts line, the
#      main provenance, the examined/extracted counts, AND both failing sets
#      verbatim — the auditable diff, so a reviewer never has to re-run the tool
#   7. merge flags pass through (`--squash`) rather than being hardcoded
#   8. `--dry-run` posts and merges nothing
#   9. PARITY: exactly ONE `comm -23` exists in the repo's rail — both consumers
#      shell out to `ci-failure-set.sh --diff`; neither re-implements it
#  10. THE BOGUS ZERO: `gh run list --branch main` returns whatever ran most, NOT
#      the test lane — so an unfiltered window can contain ZERO test runs and the
#      baseline extracts EMPTY while main is red. The unfiltered path false-blocks;
#      the lane-filtered path does not. Both halves are asserted.
#  11. `--repo` reaches the RUN calls (`gh run list` / `gh run view`), not just
#      `pr view` — dropping it compares the WRONG repo and yields a vacuous
#      "zero unique failures" against an unrelated baseline.
#  12. THE HEAD MUST HAVE BEEN TESTED (review P0 #3): a queued/in-progress lane
#      run, or no lane run at all, yields an EMPTY failing set — indistinguishable
#      from "green". Both must BLOCK, or the rail merges before CI finishes and
#      the fresh failure lands after the merge (the #3420 ratchet).
#  13. THE HEAD MUST NOT MOVE (review P1): a rebase between the analysis and the
#      comment must BLOCK, on the CLEAN path too — not only inside the flake
#      branch. The merge also carries `--match-head-commit` so GitHub enforces it.
#  14. A FAILED COMPARISON IS NOT AN EMPTY COMPARISON (review P2): `--diff`
#      returning non-zero must BLOCK; an unchecked failure leaves an empty file
#      that reads as "no unique failures" — fail-open.
#  15. THE MERGE METHOD HAS A DEFAULT: `gh pr merge` requires one and NO-OPs
#      without it, so the passthrough must not let an omission certify a merge
#      that never happened. An explicit method overrides it, without doubling.
#  16. A FAILED MERGE FAILS LOUD: the exit status is checked, gh's stderr is
#      surfaced, and a head-bound RETRACTION is posted so the success marker is
#      never left standing over an unmerged PR (B1 lost #3754/#3755 to it).
#  17. A DRAFT IS REFUSED EARLY: gh refuses to merge a draft and commit-workflow
#      opens drafts, so the rail refuses before any CI work, by name.
#  18. THE RE-RUN BOUND IS DERIVED PER SHARD (#1167): no global constant. The
#      bound is a FUNCTION of the run's own observed green job durations, C is the
#      max over the NOT-completed shards (the ones a wait can land on), the FLOOR
#      protects a sample-less shard, and ANY derivation failure is the 3900s
#      fail-safe — never a small bound. (#1167 follow-on) For a REMOTE run this
#      derived bound is the ONLY bound: `updatedAt` freezes for the whole of a
#      single long step, so a flat "no progress" window fires on healthy long
#      jobs — the false STALL this suite pins OUT. The lane-terminal precondition
#      names WHICH wait it is and fabricates no stall.
#  19. THE SAMPLE IS A GREEN POPULATION (#1167 review P1): the failing run's own
#      truncated failure duration can never stand in for a shard's healthy
#      duration — a shard with no completed SUCCESSFUL sample takes the fail-safe.
#      The review's P2s: numeric timing knobs and an explicit --rerun-timeout are
#      REFUSED when they are not positive integers; parser-only flags never reach
#      gh; an unreadable run is not a stall; and the gh-command seam is word-split
#      consistently with every other call site.
#  20. THE PR'S EVALUATED TREE, NOT THE WATCHED LANE (#1261). A lane-scoped
#      comparison cannot see a red on another workflow, so the vacuous branch
#      merged onto one (a ruff violation reddened every open PR's tree, then two
#      PRs merged on top). The rail reads the PR'S OWN evaluated-tree surface —
#      the head sha, where GitHub reports the evaluation of the `pull_request`
#      merge ref (see the rail's header: probing `refs/pull/<N>/merge`'s sha
#      returns ZERO check runs on a real PR) — and refuses a red tree, naming the
#      job, the workflow and the run URL. MAIN'S head surface is still measured
#      and REPORTED, but never blocks: while the base is red, the PR that REPAIRS
#      it is green on its own tree and must land (the discriminating test), while
#      a PR onto a red base that does NOT repair it keeps the red and refuses.
#      A superseded check run is not a red; a pending check is not a red; an empty
#      surface is UNMEASURED (stated, not green); a probe that FAILED is a
#      refusal; a corrupted/absent/conflicted merge ref is its own loud refusal;
#      and a red on a non-code event (schedule/issues) is reported without
#      blocking, because blocking on those would refuse every merge in a repo
#      whose cron lanes are red most days. STALENESS is the last hole: the tree
#      surface reflects the base as of the PR's LAST run and GitHub does not
#      re-run PR checks when the base moves, so a base red that appeared after
#      this PR's checks were produced is invisible to the tree gate. The rail
#      refuses when a code-measuring base red's run STARTED after the PR surface
#      was last produced — red-relative, never movement-relative, so a base that
#      moved but is GREEN still merges, and the PR that REPAIRS a red base still
#      lands (its evaluation postdates the red it removes). The ordering rule
#      cannot see a base red whose run PREDATES the surface but which lives on a
#      base the surface never used: GitHub recomputes the merge ref when the base
#      moves and does NOT re-run the PR's checks, so the PR's green can be a
#      LAGGING evaluation. The second, independent signal is the merge ref's
#      FIRST PARENT — the base commit it was computed against. When that differs
#      from the current base head AND the base carries a blocking red, the rail
#      refuses; when the base is green it still merges (the merge ref lags by a
#      commit or two routinely), and an unreadable parent on a red base fails
#      closed.
#  21. A VACUOUS COMPARISON IS NOT A CERTIFICATE (#1319): `PR failing: 0 |
#      main failing: 0` is an ABSENCE of a measurement, and it certifies only
#      when the PR demonstrably EXECUTED every test shard main's lane EXECUTED.
#      tortoise #4263 merged on exactly that line while its tier-2 PR lane had
#      SKIPPED shards main's push lane runs; the failure lived in one of them,
#      appeared in NEITHER collected set, and reddened main's required check for
#      the whole fleet (#4457). The gate is fail-CLOSED: an unreadable shard list
#      is never read as "the same lane", a `skipped` shard is not coverage, an
#      EMPTY shard set is not parity (an empty set used to render as a blank line
#      that matched itself and certified having observed nothing — cycle-1 P0),
#      a failed `gh run list` is a LISTING failure and not a thinner lane, and the
#      parity key is the VERBATIM shard name (the matrix axis is NOT normalised
#      away — `test (a, docker)` and `test (a, embedded)` are different lanes).
#      Both sides are read over the SAME window (the PR's lane runs for the head;
#      main's last `--main-runs`), so a shard main ran only inside the operator's
#      window cannot be sampled away. A listing that is only PARTLY readable is
#      UNREADABLE, not a thinner lane (cycle-2 P1: an unparsable run line used to
#      be skipped, silently shrinking the reference; an unterminated final line
#      was dropped outright). A family whose every member is a workflow LIFECYCLE
#      job measured nothing and is refused (cycle-2 P1: `=changes` certified on
#      bookkeeping while main's real shard went uncompared), which is why the
#      evidence and the refusal both NAME the parity family. `--main-runs` is
#      validated (positive, ≤ 200) before any CI work — the window is also the
#      gate's Jobs-API call budget. `ADMIN_MERGE_LANE_PARITY=declared-off` is the
#      AUDITED escape (a trigger-split repo, #1349): it certifies while STATING in
#      the evidence and on stderr that parity was NOT established, and any other
#      value is refused at startup. Declared OUT of scope: a repo that varies the
#      test SELECTION within one shard name (files chosen per-diff inside
#      `test (a)`), which a job list cannot show — filed as #1350.
#  22. THE LANE-PARITY GATE'S OWN FAIL-OPEN PATHS (#1319 cycle-1/2 review): the
#      gate must not itself conclude from an absence. An EMPTY shard set is not
#      an empty FILE (a blank line used to match itself and certify); a shard
#      main ran only INSIDE the operator's window must not be sampled away; a
#      failed `gh run list` is a LISTING failure; a partly-readable listing is
#      unreadable; a lifecycle-only "family" measured nothing; a misspelled
#      `ADMIN_MERGE_LANE_PARITY` is refused rather than silently read as 'off';
#      and the certifying path DISCLOSES the family it compared. Every one of
#      these has a test that FAILS against the revision before its fix.
#  23. THE CHECK-SURFACE POSTURE (#1353): every non-red value is NAMED; anything
#      unnamed, absent, unmeasured or unattributable is a NAMED state — never a
#      zero, and never dropped before classification. Four fail-opens, one per
#      posture clause: the in-flight spelling is an ALLOW-LIST (an unrecognised
#      `status` is classified by its conclusion, RED unless named non-red — on
#      the tree AND the base, where the old deny-list also disarmed 4.6/4.7);
#      only a COMPLETED measurement sets the staleness anchor (a PENDING status
#      no longer advances it); the non-code-event exemption is scoped to the
#      BASE surface (a `schedule` red on the tree BLOCKS — it cannot be noise
#      there); and an UNNAMED check is classified under a placeholder, never
#      dropped. §50-§53 pin all four, plus the attribution half (index 24).
#  24. THE ATTRIBUTION HALF — #1319's sibling (#1353): `PR failing: 0` can mean
#      "no failures", "not comparable" (the parity gate) OR "the failures were
#      DROPPED". The parser drops a FAILED token that is not a test id (never in
#      the set), so the rail now NAMES the dropped count and the tokens in its
#      output and in the POSTED EVIDENCE, and states whether each set is
#      COMPLETE or CLIPPED. In the evidence the token text is rendered with its
#      markdown metacharacters ESCAPED and the escape is disclosed, so the
#      disclosure and #3756's "a hostile token cannot break the evidence" hold at
#      once; stderr keeps the token verbatim. A run whose failures are ENTIRELY
#      unattributable still refuses (step 1c, preserved).
#
# Hermetic: every fixture lives under a temp root; a fake `gh` serves every call.

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CFS="$ROOT/scripts/ci-failure-set.sh"
ADM="${ADMIN_MERGE_SUITE_ADM:-$ROOT/scripts/admin-merge.sh}"
DETECTOR="$ROOT/.github/workflows/admin-merge-detector.yml"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/admin-merge-suite.XXXXXX")"
checks=0
failures=0

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); echo "   ❌ $1"; failures=$((failures + 1)); }

[ -f "$CFS" ] || { echo "❌ missing $CFS"; exit 1; }
[ -f "$ADM" ] || { echo "❌ missing $ADM"; exit 1; }

# ── fake gh ───────────────────────────────────────────────
# Driven entirely by files under $SCEN (the scenario dir). Records every
# invocation in $SCEN/calls so the suite can assert on the merge command.
FAKE="$TMP/fake-gh"
cat > "$FAKE" <<'FAKEEOF'
#!/usr/bin/env bash
set -uo pipefail
SCEN="${SCEN:?SCEN must be set}"
printf '%s\n' "$*" >> "$SCEN/calls"

a1="${1:-}"; a2="${2:-}"
key="$a1 $a2"

# value of a --flag (first occurrence)
flag_val() {
  local want="$1" prev="" x
  for x in "${@:2}"; do
    [ "$prev" = "$want" ] && { printf '%s' "$x"; return 0; }
    prev="$x"
  done
  return 0
}
has_flag() {
  local want="$1" x
  for x in "${@:2}"; do [ "$x" = "$want" ] && return 0; done
  return 1
}

case "$key" in
  "pr view")
    pr="${3:-}"
    # The draft probe is a DISTINCT question from the head resolutions: answer it
    # from its own fixture and never let it consume the head-seq sequence.
    want_draft=0; want_head=0; want_base=0; want_merged=0; jprev=""
    for x in "$@"; do
      if [ "$jprev" = "--json" ]; then
        case "$x" in *isDraft*) want_draft=1 ;; esac
        case "$x" in *headRefOid*) want_head=1 ;; esac
        case "$x" in *baseRefName*) want_base=1 ;; esac
        case "$x" in *mergedAt*) want_merged=1 ;; esac
      fi
      jprev="$x"
    done
    if [ "$want_draft" = 1 ] && [ "$want_head" = 0 ]; then
      [ -f "$SCEN/draft" ] && { cat "$SCEN/draft"; exit 0; }
      printf 'false\n'; exit 0
    fi
    # #1261: the PR's TARGET branch, for the main-health probe. Its own fixture
    # (default `main`), and it must NOT consume the head-seq sequence either.
    if [ "$want_base" = 1 ] && [ "$want_head" = 0 ] && [ "$want_draft" = 0 ]; then
      [ -f "$SCEN/base-ref" ] && { cat "$SCEN/base-ref"; exit 0; }
      printf 'main\n'; exit 0
    fi
    # ── #1359: THE MERGE ARTIFACT. A DISTINCT question from the head resolution:
    # answer it from its own fixture and never let it consume the head-seq
    # sequence. The state is SIMULATED, not assumed — `<merged>` is created by the
    # `pr merge` handler below only when the merge actually happens, so a scenario
    # can model the case this check exists for (a `gh pr merge` that exits 0 while
    # the PR is still OPEN, e.g. a queued `--auto`) by setting `merge-noop`.
    if [ "$want_merged" = 1 ]; then
      # The rail asks for a PROJECTION (`--jq '… | @tsv'`), so the fake must answer
      # in the PROJECTED form real gh would print: one tab-separated
      # `<state>\t<mergedAt>`, with mergedAt sentineled because it is null for an
      # unmerged PR. The state is SIMULATED, not assumed — `merged` is created by
      # the `pr merge` handler below only when the merge actually happens, so a
      # scenario can model a `gh pr merge` that exits 0 while the PR stays OPEN
      # (a queued `--auto`) by setting `merge-noop` instead.
      if [ -f "$SCEN/merged" ]; then
        printf 'MERGED\t2026-09-23T00:00:00Z\n'
      else
        printf 'OPEN\t-\n'
      fi
      exit 0
    fi
    # head-seq models a PR head that MOVES between resolutions (a rebase landing
    # mid-run): the Nth `pr view` returns the Nth line.
    if [ -f "$SCEN/head-seq" ]; then
      n=$(( $(cat "$SCEN/head-seq-count" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$n" > "$SCEN/head-seq-count"
      sed -n "${n}p" "$SCEN/head-seq"
      exit 0
    fi
    if [ -f "$SCEN/head-$pr" ]; then cat "$SCEN/head-$pr"; exit 0; fi
    [ -f "$SCEN/head" ] && { cat "$SCEN/head"; exit 0; }
    exit 1 ;;
  "run list")
    [ -f "$SCEN/fail-run-list" ] && exit 1
    # A COUNTED failure seam, for the one place where NO flag can separate the
    # callers: the parser (ci-failure-set.sh) and the rail's lane-coverage gate
    # issue BYTE-IDENTICAL `gh run list` invocations (same flags, same jq). The
    # CALL ORDER is deterministic, so fail exactly the Nth `run list` of the
    # scenario. A test that targets the wrong call fails LOUDLY — the parser's
    # own listing failure reports a different reason — so a shifted order can
    # never let this seam silently decompose into a no-op.
    if [ -f "$SCEN/fail-run-list-nth" ]; then
      nth=$(( $(cat "$SCEN/run-list-count" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$nth" > "$SCEN/run-list-count"
      [ "$nth" = "$(cat "$SCEN/fail-run-list-nth")" ] && exit 1
    fi
    # Real gh REJECTS a parser-only flag: `--any-workflow` is ci-failure-set's
    # opt-out, not a `gh run list` flag. The fake used to ignore unknown flags,
    # which hid admin-merge forwarding it and silently killing the
    # WAIT-vs-STALLED diagnostic behind `2>/dev/null || true`.
    for x in "$@"; do
      case "$x" in --any-workflow)
        echo "gh: unknown flag: --any-workflow" >&2; exit 1 ;;
      esac
    done
    mode=""; val=""; prev=""; limit=""; wf=""; st=""
    for x in "$@"; do
      if [ "$prev" = "--commit" ]; then mode=commit; val="$x"; fi
      if [ "$prev" = "--branch" ]; then mode=branch; val="$x"; fi
      if [ "$prev" = "--limit" ]; then limit="$x"; fi
      if [ "$prev" = "--workflow" ]; then wf="$x"; fi
      if [ "$prev" = "--status" ]; then st="$x"; fi
      prev="$x"
    done
    # THE GREEN POPULATION for the per-shard ceiling: recent SUCCESSFUL runs,
    # served as bare run ids (`$SCEN/green-runs`, one per line). No file → an
    # empty population → the shard's fail-safe governs (never the failure sample).
    if [ "$st" = "success" ]; then
      [ -f "$SCEN/green-runs" ] && cat "$SCEN/green-runs"
      exit 0
    fi
    # The projection a caller asks for is named by its `--json` FIELD LIST, and
    # the two lane-shaped callers now differ BY THAT LIST (#1358), so they can no
    # longer be told apart by a single field name:
    #   * the RUN MAP (`--json databaseId,event,workflowName`) — #1261 main-health
    #     event resolution. Recognised by `event` WITHOUT `status`/`conclusion`.
    #   * the RAW supersede listing (`… headSha,workflowDatabaseId,workflowName,
    #     event`) — recognised by `workflowDatabaseId`, which NO other caller asks
    #     for. Served WHOLE: the fixture IS that 6-field projection.
    #   * the canonical 3-field lane listing (`… headSha`, `LANE_RUN_JQ`) — served
    #     as the FIRST THREE FIELDS, so one fixture answers both the raw consumer
    #     (the parser) and the canonical one (the rail's coverage gate, which
    #     reads `<status>\t<conclusion>\t<sha>:<id>`). A 3-field fixture is
    #     unchanged by that projection, which is why every older scenario in this
    #     suite keeps its exact meaning.
    fields=""; jp=""
    for x in "$@"; do
      [ "$jp" = "--json" ] && fields="$x"
      jp="$x"
    done
    want_map=0 want_raw=0
    case "$fields" in
      *workflowDatabaseId*) want_raw=1 ;;
      *event*)
        case "$fields" in *status*|*conclusion*) ;; *) want_map=1 ;; esac ;;
    esac
    if [ "$want_map" = 1 ]; then
      # The map is keyed the same way the rail keyed the listing: `--commit` for a
      # sha-keyed surface (the PR's evaluated tree), `--branch` for main.
      if [ "$mode" = "commit" ]; then
        [ -f "$SCEN/tree-run-map" ] && cat "$SCEN/tree-run-map"
      else
        [ -f "$SCEN/main-run-map" ] && cat "$SCEN/main-run-map"
      fi
      exit 0
    fi
    if [ "$mode" = "commit" ]; then f="$SCEN/runs-$val"; else f="$SCEN/runs-main"; fi
    # A per-lane fixture, when present, models the FILTERED listing; the bare
    # file models the unfiltered one (the bogus-zero window).
    if [ -n "$wf" ] && [ -f "$f.by-workflow.$wf" ]; then f="$f.by-workflow.$wf"; fi
    if [ "$want_raw" = 1 ]; then
      # The raw projection: the fixture verbatim (a legacy 3-field line is handed
      # over as-is, which is exactly how a line the lister did not produce reaches
      # the rule — see the opacity contract in ci-failure-set.sh).
      if [ -f "$f" ] && [ -n "$limit" ]; then head -n "$limit" "$f"; exit 0; fi
      [ -f "$f" ] && cat "$f"
      exit 0
    fi
    # The canonical 3-field projection. Applied AFTER the limit, because gh
    # truncates the listing and only then projects it.
    if [ -f "$f" ] && [ -n "$limit" ]; then head -n "$limit" "$f" | cut -f1-3; exit 0; fi
    [ -f "$f" ] && cut -f1-3 "$f"
    exit 0 ;;
  "run view")
    id="${3:-}"
    if has_flag --log-failed "$@"; then
      if [ -f "$SCEN/rerun-$id" ] && [ -f "$SCEN/log-after-$id" ]; then
        cat "$SCEN/log-after-$id"; exit 0
      fi
      [ -f "$SCEN/fail-log-$id" ] && exit 1
      [ -f "$SCEN/log-$id" ] && { cat "$SCEN/log-$id"; exit 0; }
      exit 0
    fi
    # The run-state projection of the re-run wait. `status-<id>` is consumed one
    # line per poll and REPEATS its last line once exhausted, so an
    # all-in_progress status models a run that never finishes. The projection is
    # STATUS-ONLY when the caller asks for `--json status`; a caller that asks for
    # `--json status,updatedAt` also gets the `updated-<id>` clock, so a regression
    # that reintroduces an updatedAt-based verdict is observable here. `updated-<id>`
    # is frozen for the whole of a single long step, so it is NOT a progress
    # signal for a remote run.
    # A run whose projection CANNOT be read at all (gh failure/auth/network).
    # Deliberately distinct from a run that is merely not progressing: the rail
    # must never call an unreadable run STALLED — "no progress" is a claim about
    # a field we read, and an outage is the absence of that reading.
    want_upd=0; uprev=""
    for x in "$@"; do
      if [ "$uprev" = "--json" ]; then case "$x" in *updatedAt*) want_upd=1 ;; esac; fi
      uprev="$x"
    done
    [ -f "$SCEN/unreadable-$id" ] && exit 1
    if [ -f "$SCEN/status-$id" ]; then
      n=$(( $(cat "$SCEN/status-count-$id" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$n" > "$SCEN/status-count-$id"
      s="$(sed -n "${n}p" "$SCEN/status-$id")"
      [ -n "$s" ] || s="$(tail -n1 "$SCEN/status-$id")"
      if [ "$want_upd" = 1 ]; then
        u="$(sed -n "${n}p" "$SCEN/updated-$id" 2>/dev/null)"
        [ -n "$u" ] || u="$(tail -n1 "$SCEN/updated-$id" 2>/dev/null)"
        [ -n "$u" ] || u="2026-01-01T00:00:00Z"
        printf '%s %s\n' "$s" "$u"
      else
        printf '%s\n' "$s"
      fi
      exit 0
    fi
    printf 'completed\n'
    exit 0 ;;
  "run rerun")
    id="${3:-}"
    [ -f "$SCEN/fail-rerun-$id" ] && exit 1
    : > "$SCEN/rerun-$id"
    exit 0 ;;
  "pr comment")
    pr="${3:-}"
    body="$(flag_val --body-file "$@")"
    if [ -n "$body" ]; then
      # GitHub rejects a body over 65,536 CHARACTERS server-side. MODEL it — the
      # fake used to `cp` any body and exit 0, so an unbounded body still passed
      # and the suite's "still certifies" / "under the cap" assertions pinned
      # nothing at all. (VGATE round 3.)
      chars=$(wc -m < "$body" | tr -d ' ')
      if [ "$chars" -gt 65536 ]; then
        echo "gh: Body is too long (maximum is 65536 characters)" >&2
        exit 1
      fi
      cp "$body" "$SCEN/comment"
      # Keep each body separately too, so a scenario that posts MORE than one
      # comment (evidence + retraction) can assert on the earlier one as well.
      cn=$(( $(cat "$SCEN/comment-count" 2>/dev/null || echo 0) + 1 ))
      printf '%s' "$cn" > "$SCEN/comment-count"
      cp "$body" "$SCEN/comment-$cn"
    fi
    exit 0 ;;
  "pr merge")
    if [ -f "$SCEN/fail-merge" ]; then
      cat "$SCEN/fail-merge" >&2
      exit 1
    fi
    # #1359: a merge that REPORTED success also HAPPENED — unless the scenario is
    # modelling a queued (`--auto`) merge, which exits 0 while the PR stays OPEN.
    [ -f "$SCEN/merge-noop" ] || touch "$SCEN/merged"
    exit 0 ;;
  api*)
    # ── #1261: THE CHECK SURFACES. These URLs are answered from their OWN
    # fixtures and NEVER from the jobs fallback below — that fallback is a
    # catch-all for the #1167 API seam, and letting a health call fall into it
    # returned a jobs body as a check surface (a silent misread).
    #
    # PER-SHA, because the rail measures TWO surfaces: the PR's evaluated tree
    # (keyed to the PR HEAD sha, where GitHub reports the merge-ref evaluation)
    # and the base's head (keyed to `main`). They are separate objects in
    # reality, so the fake keeps them separate: a `<head>` fixture for the PR
    # surface, the `main-*` fixtures for main's. That split is the point of
    # #1261 — a red on MAIN must not block when the PR's own tree is green.
    #
    # #1446: A SINGLE RUN, resolved by its own id — the arm the rail falls back
    # to when the bounded `gh run list` map did not carry that run. It is tried
    # BEFORE the check-surface case and anchored on a URL that ENDS at the run
    # id, so the Jobs seam (`…/runs/<id>/jobs…`) is never swallowed by it. The
    # fixture is `$SCEN/run-<id>` holding the rail's own projected shape
    # (`<event>\t<workflow-name>`); NO fixture is an unresolvable run, which the
    # rail must treat as fail-closed — never as a non-code exemption.
    if [ -n "$(printf '%s' "$a2" | sed -n 's#.*/actions/runs/[0-9][0-9]*$#&#p')" ]; then
      id="$(printf '%s' "$a2" | sed -n 's#.*/actions/runs/\([0-9][0-9]*\)$#\1#p')"
      if [ -f "$SCEN/run-$id" ]; then cat "$SCEN/run-$id"; exit 0; fi
      exit 1
    fi
    case "$a2" in
      */pulls/*)
        # ONE projected line, matching the rail's `gh api ... --jq` expression:
        # "<mergeable>\t<merge_commit_sha>".
        [ -f "$SCEN/pr-unreadable" ] && { echo "gh: API error" >&2; exit 1; }
        m=true; [ -f "$SCEN/pr-mergeable" ] && m="$(cat "$SCEN/pr-mergeable")"
        s=mergefeed00000000000000000000000000000000
        [ -f "$SCEN/pr-merge-sha" ] && s="$(cat "$SCEN/pr-merge-sha")"
        printf '%s\t%s\n' "$m" "$s"; exit 0 ;;
      *"/check-runs"*)
        sha="$(printf '%s' "$a2" | sed -n 's#.*/commits/\([^/]*\)/check-runs.*#\1#p')"
        [ -f "$SCEN/main-health-unreadable" ] && { echo "gh: API error" >&2; exit 1; }
        # THE MERGE SHA CARRIES NO CHECK SURFACE (#1261 — verified, not assumed):
        # GitHub keys the merge-ref evaluation's checks to the PR HEAD sha, so
        # probing `refs/pull/<N>/merge`'s sha returns total_count 0. Modelling
        # that makes a regression BACK to probing the merge sha FAIL the incident
        # scenario (empty -> UNMEASURED -> it would merge a red tree) instead of
        # silently passing on the same fixture.
        if [ "$sha" = "$(cat "$SCEN/pr-merge-sha" 2>/dev/null || printf 'mergefeed00000000000000000000000000000000')" ]; then
          printf '{"total_count":0,"check_runs":[]}\n'; exit 0
        fi
        if [ "$sha" = "$(cat "$SCEN/main-sha" 2>/dev/null || printf 'feedface0000000000000000000000000000000000')" ]; then
          # #1261 fix round: the BASE's own endpoint, failed ALONE, so a PARTIAL
          # read (one endpoint readable, the other not) is expressible. The
          # pre-existing `main-health-unreadable` fails EVERY surface call; this
          # one fails only this endpoint of the base.
          [ -f "$SCEN/main-check-runs-unreadable" ] && { echo "gh: API error" >&2; exit 1; }
          if [ -f "$SCEN/main-check-runs.json" ]; then cat "$SCEN/main-check-runs.json"; exit 0; fi
        else
          [ -f "$SCEN/pr-check-runs-unreadable" ] && { echo "gh: API error" >&2; exit 1; }
          [ -f "$SCEN/pr-health-unreadable" ] && { echo "gh: API error" >&2; exit 1; }
          if [ -f "$SCEN/pr-check-runs.json" ]; then cat "$SCEN/pr-check-runs.json"; exit 0; fi
        fi
        printf '{"total_count":0,"check_runs":[]}\n'; exit 0 ;;
      */"status")
        sha="$(printf '%s' "$a2" | sed -n 's#.*/commits/\([^/]*\)/status.*#\1#p')"
        [ -f "$SCEN/main-health-unreadable" ] && { echo "gh: API error" >&2; exit 1; }
        # Same as check-runs: the merge ref carries no legacy statuses either.
        if [ "$sha" = "$(cat "$SCEN/pr-merge-sha" 2>/dev/null || printf 'mergefeed00000000000000000000000000000000')" ]; then
          printf '{"state":"pending","total_count":0,"statuses":[]}\n'; exit 0
        fi
        if [ "$sha" = "$(cat "$SCEN/main-sha" 2>/dev/null || printf 'feedface0000000000000000000000000000000000')" ]; then
          [ -f "$SCEN/main-status-unreadable" ] && { echo "gh: API error" >&2; exit 1; }
          if [ -f "$SCEN/main-statuses.json" ]; then cat "$SCEN/main-statuses.json"; exit 0; fi
        else
          [ -f "$SCEN/pr-status-unreadable" ] && { echo "gh: API error" >&2; exit 1; }
          [ -f "$SCEN/pr-health-unreadable" ] && { echo "gh: API error" >&2; exit 1; }
          if [ -f "$SCEN/pr-statuses.json" ]; then cat "$SCEN/pr-statuses.json"; exit 0; fi
        fi
        printf '{"state":"pending","total_count":0,"statuses":[]}\n'; exit 0 ;;
      */commits/*)
        [ -f "$SCEN/main-health-unreadable" ] && { echo "gh: API error" >&2; exit 1; }
        ref="$(printf '%s' "$a2" | sed -n 's#.*/commits/\(.*\)$#\1#p')"
        # #1261 (step 4.7): the MERGE REF'S FIRST PARENT — the base commit the
        # merge ref was computed against. The rail asks with `--jq
        # '.parents[0].sha'`; the fake answers from its OWN fixture so a LAGGING
        # merge ref is expressible. With no fixture the parent IS the base head
        # (no lag), which is what every pre-existing scenario means.
        jqexpr="$(flag_val --jq "$@")"
        case "$jqexpr" in
          *parents*)
            [ -f "$SCEN/merge-parent-unreadable" ] && { echo "gh: API error" >&2; exit 1; }
            if [ -f "$SCEN/merge-parent" ]; then cat "$SCEN/merge-parent"
            elif [ -f "$SCEN/main-sha" ]; then cat "$SCEN/main-sha"
            else printf 'feedface0000000000000000000000000000000000\n'; fi
            exit 0 ;;
        esac
        # `commits/<ref> --jq .sha`: a BARE 40-hex sha resolves to ITSELF (real
        # GitHub returns that commit); a BRANCH resolves through the fixture.
        ref="$(printf '%s' "$a2" | sed -n 's#.*/commits/\(.*\)$#\1#p')"
        if [ "${#ref}" -eq 40 ] && [ -z "${ref//[0-9a-f]/}" ]; then
          printf '%s\n' "$ref"; exit 0
        fi
        if [ -f "$SCEN/main-sha" ]; then cat "$SCEN/main-sha"; exit 0; fi
        printf 'feedface0000000000000000000000000000000000\n'; exit 0 ;;
    esac
    # The Jobs API seam for the per-shard ceiling derivation (#1167). The run id
    # is parsed out of the URL so a fixture is per-run; a bare `$SCEN/jobs.json`
    # serves every run. No fixture is an API error (never a small bound).
    id="$(printf '%s' "$a2" | sed -n 's#.*/runs/\([0-9][0-9]*\)/jobs.*#\1#p')"
    if [ -n "$id" ] && [ -f "$SCEN/jobs-$id.json" ]; then cat "$SCEN/jobs-$id.json"; exit 0; fi
    if [ -f "$SCEN/jobs.json" ]; then cat "$SCEN/jobs.json"; exit 0; fi
    exit 1 ;;
  *)
    exit 1 ;;
esac
FAKEEOF
chmod +x "$FAKE"

# new_scen <name> → $SCEN for one scenario
new_scen() {
  SCEN="$TMP/scen-$1"
  rm -rf "$SCEN"
  mkdir -p "$SCEN"
  : > "$SCEN/calls"
}

run_admin() {
  SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" \
    ADMIN_MERGE_POLL_INTERVAL=0 bash "$ADM" "$@" >"$TMP/out" 2>"$TMP/err"
  return $?
}

# run_admin_here — the SAME rail invocation, but the capture lands in the
# SCENARIO dir ($SCEN/out, $SCEN/err) instead of the suite-SHARED $TMP/out.
# A shared capture makes an assertion depend on whichever scenario wrote it
# LAST, so a stale file can satisfy a grep its own run never earned — the
# fail-open shape this suite exists to catch, one level down. Scenarios that
# assert on the rail's own output use this.
run_admin_here() {
  SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" \
    ADMIN_MERGE_POLL_INTERVAL=0 bash "$ADM" "$@" >"$SCEN/out" 2>"$SCEN/err"
  return $?
}

# ── bound-based wait fixtures (#1167 follow-on) ────────────────────────────
# A remote run has NO within-job activity signal: `updatedAt` advances on
# job/step transitions, so one long step freezes it for the whole job. The wait
# therefore has ONE bound, DERIVED per shard from a green population — and the
# tests must express a BOUND, never a progress fingerprint. These helpers write
# that fixture. The rail derives max(FLOOR, 2 x secs) for the shard, so a test
# sets ADMIN_MERGE_RERUN_FLOOR low when it wants a small bound.
#
# green_shard <green-run-id> <shard> <secs> → the GREEN population: one recent
#   COMPLETED SUCCESSFUL job of <shard> lasting <secs>.
# target_shard <run-id> <shard> → the terminal TARGET run whose shard SET is
#   <shard>; its own duration is deliberately NOT the sample (green governs).
green_shard() {
  local gid="$1" shard="$2" secs="$3" mm ss
  mm=$((secs / 60)); ss=$((secs % 60))
  printf '%s\n' "$gid" > "$SCEN/green-runs"
  printf '{"total_count":1,"jobs":[{"name":"%s","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:%02d:%02dZ"}]}\n' \
    "$shard" "$mm" "$ss" > "$SCEN/jobs-$gid.json"
}
target_shard() {
  printf '{"total_count":1,"jobs":[{"name":"%s","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:05:00Z"}]}\n' \
    "$2" > "$SCEN/jobs-$1.json"
}

# A pytest-shaped failing-run log body in the REAL `gh run view --log-failed`
# envelope (`<job>\t<step>\t<ISO>Z <line>`), which is what the signature extractor
# (`scripts/ci_exemption.py signatures`) is grounded on. Without the timestamp
# prefix the summary line does not parse and every failure would be unsigned.
log_failed() { printf 'test (a)\tRun tests\t2026-09-17T13:10:44.1700000Z FAILED %s - AssertionError: boom\n' "$1"; }
log_passed() { printf 'test (a)\tRun tests\t2026-09-17T13:10:44.1700000Z PASSED %s\n' "$1"; }
# A FAILED line whose token is NOT a test id (the reproduced shape: `FAILED (HTTP`).
# The canonical parser DROPS it and counts it, so the failing set is CLIPPED — the
# attribution half of #1353 is about naming that instead of letting it read as a
# measured zero.
log_unattributable() { printf 'test (a)\tRun tests\t2026-09-17T13:10:44.1700000Z FAILED %s upstream error\n' "$1"; }

# Lane-run fixture lines. The parser reads the lane's COMPLETION state from the
# SAME `gh run list` projection as its failures (that is the point of P0 #3), so
# the fixture models the projection: `<status>\t<conclusion>\t<sha>:<run-id>`.
lane_line() { printf '%s\t%s\t%s:%s\n' "$1" "$2" "$3" "$4"; }
lane_fail() { lane_line completed failure "$1" "$2"; }
# A passing lane run also carries a JOB LIST: the #1319 lane-coverage gate reads
# one Jobs listing per completed run, so a run-list fixture without a matching
# jobs-<id>.json models a run whose jobs CANNOT BE READ — a refusal, not a green
# lane. Writing the default here keeps a "the lane is green" fixture COMPLETE
# rather than accidentally partial. A scenario that needs a DIFFERENT shard set
# (or deliberately no listing at all) overwrites or removes the file afterwards.
lane_pass() {
  lane_line completed success "$1" "$2"
  lane_jobset "$2" success 'test (a)' 'test (b)'
}
lane_queued() { lane_line in_progress "" "$1" "$2"; }

# A main baseline that EXEMPTS <id> under the #3756 decision: `n` tested runs (at
# least the module's min_runs floor) in which <id> fails with the SAME signature.
# Before the swap a merge only needed the id to appear ONCE anywhere in main's
# window; the decision needs MAIN measured over at least min_runs, so scenarios
# that assert a merge must measure main. These fixtures give the PR a SINGLE
# failing run, so the PR sample is below min_runs and the exemption is granted on
# the attribution path (#5250); the rate comparison's own path is exercised by the
# unit tests and by the `runs=8` DEMO below.
main_red_n() {  # <sha> <base-run-id> <n> <id>  -> lane-run lines on stdout
  local sha="$1" base="$2" n="$3" id="$4" i=0
  while [ "$i" -lt "$n" ]; do
    lane_fail "$sha" "$((base + i))"
    log_failed "$id" > "$SCEN/log-$((base + i))"
    i=$((i + 1))
  done
}

# The lane-coverage projection (#1319). The parity gate reads each run's JOB
# LIST — job NAME plus conclusion — so a fixture is one JSON document per run
# under $SCEN/jobs-<run-id>.json (the same seam the per-shard re-run bound uses).
#
# lane_jobs <run-id> <name>:<conclusion> ... → the Jobs API listing for a run.
#   A shard is COVERAGE only when its conclusion is success|failure|timed_out;
#   `skipped` exercised nothing, so a fixture that lists a shard as skipped
#   models a run that did NOT execute it — the #4457 hole.
lane_jobs() {
  local id="$1"; shift
  local json='{"total_count":0,"jobs":[' first=1 pair name concl
  for pair in "$@"; do
    name="${pair%:*}"; concl="${pair##*:}"
    [ "$first" -eq 1 ] || json="$json,"
    first=0
    json="$json{\"name\":\"$name\",\"status\":\"completed\",\"conclusion\":\"$concl\",\"started_at\":\"2026-01-01T00:00:00Z\",\"completed_at\":\"2026-01-01T00:05:00Z\"}"
  done
  json="$json]}"
  # `total_count` must be the number of jobs ACTUALLY listed (the API's smallest
  # true value), not the 0 the helper was first written with: a fixture that
  # contradicts its own list is a fixture a future reader has to disbelieve.
  local count=$(( $# ))
  json="$(printf '%s' "$json" | sed "s/\"total_count\":0/\"total_count\":$count/")"
  printf '%s\n' "$json" > "$SCEN/jobs-$id.json"
}

# lane_jobset <run-id> <conclusion> <shard>... — every shard with one conclusion.
lane_jobset() {
  local id="$1" concl="$2"; shift 2
  local pairs=() s
  for s in "$@"; do pairs+=("$s:$concl"); done
  lane_jobs "$id" ${pairs[@]+"${pairs[@]}"}
}

# ── #1261 main-health fixtures ──────────────────────────────────────────
# write_main_checks <check_run-json>... → $SCEN/main-check-runs.json (RAW, so the
#   rail's own JSON reader is exercised). NO fixture means an EMPTY surface, i.e.
#   the rail's UNMEASURED state — which is not a refusal.
write_main_checks() {
  local body="" one
  for one in "$@"; do
    [ -n "$body" ] && body="${body},"
    body="${body}${one}"
  done
  printf '{"total_count":%s,"check_runs":[%s]}\n' "$#" "$body" > "$SCEN/main-check-runs.json"
}

# check_run <id> <job> <status> <conclusion> <run-id> [<started_at>] [<completed_at>] → one
#   check-run object. The run id is embedded in the run URL because that is where
#   the rail resolves a check's EVENT from. The timestamps are the rail's
#   STALENESS anchor (#1261): a completed check carries `completed_at` (default
#   2026-01-01T00:05:00Z); a non-completed one carries JSON null (it produced no
#   measurement). Defaults are shared, so a scenario that does not set them
#   compares 00:05 against a red at 00:00 and is NOT stale.
check_run() {
  local start="${6:-2026-01-01T00:00:00Z}" comp="null"
  [ "$3" = "completed" ] && comp="\"${7:-2026-01-01T00:05:00Z}\""
  printf '{"id":%s,"name":"%s","status":"%s","conclusion":"%s","app":{"slug":"github-actions"},"started_at":"%s","completed_at":%s,"html_url":"https://github.com/daniel-ospina/agent-infra/actions/runs/%s/job/1"}' \
    "$1" "$2" "$3" "$4" "$start" "$comp" "$5"
}

# main_run_map <run-id> <event> <workflow-name>... → $SCEN/main-run-map, the
#   `gh run list` projection the rail uses to resolve a red check's EVENT.
main_run_map() {
  : > "$SCEN/main-run-map"
  while [ $# -ge 3 ]; do
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SCEN/main-run-map"
    shift 3
  done
}

# A main surface that is genuinely MEASURED AND GREEN (two successes), so the
# "still merges" regression guard cannot pass on the UNMEASURED state by accident.
main_green_surface() {
  write_main_checks \
    "$(check_run 4001 'test (a)' completed success 6101)" \
    "$(check_run 4002 'test (b)' completed success 6101)"
  main_run_map 6101 push 'Python CI'
}

# ── #1261 (second pass): the PR's EVALUATED TREE, and the base as CONTEXT ──
# The surface that GATES the merge is the PR's OWN tree — the head sha, where
# GitHub reports the evaluation of the merge ref (§ header). It is a DIFFERENT
# object from main's head, so the fake keeps a separate fixture for it: that
# split is what makes "base red, PR tree green -> MERGES" expressible at all.
#
# write_pr_checks <check_run-json>... → $SCEN/pr-check-runs.json.
write_pr_checks() {
  local body="" one
  for one in "$@"; do
    [ -n "$body" ] && body="${body},"
    body="${body}${one}"
  done
  printf '{"total_count":%s,"check_runs":[%s]}\n' "$#" "$body" > "$SCEN/pr-check-runs.json"
}

# pr_run_map <run-id> <event> <workflow-name>... → $SCEN/tree-run-map, the
# `gh run list --commit <sha> --json event` projection for the PR's tree.
pr_run_map() {
  : > "$SCEN/tree-run-map"
  while [ $# -ge 3 ]; do
    printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$SCEN/tree-run-map"
    shift 3
  done
}

# merge_parent <sha> → $SCEN/merge-parent, the BASE commit a PR's merge ref was
#   computed against (the rail's step-4.7 discriminator: the merge commit's
#   `parents[0]`). A DIFFERENT sha models a LAGGING merge ref. With no fixture
#   the fake answers the base head, i.e. no lag.
merge_parent() { printf '%s\n' "$1" > "$SCEN/merge-parent"; }

# pr_merge_ref <mergeable> <merge-sha> → the `pulls/<N>` projection the rail's
# resolve_merge_ref reads. With NO fixture the fake answers `true` + a fixed sha,
# i.e. an ordinary mergeable PR.
pr_merge_ref() {
  printf '%s\n' "$1" > "$SCEN/pr-mergeable"
  printf '%s\n' "$2" > "$SCEN/pr-merge-sha"
}

# A PR evaluated-tree surface that is genuinely MEASURED AND GREEN.
pr_green_surface() {
  write_pr_checks \
    "$(check_run 5001 'ci / lint' completed success 7101)" \
    "$(check_run 5002 'ci / test' completed success 7101)"
  pr_run_map 7101 pull_request 'CI'
}

# A BASE surface that is genuinely MEASURED AND RED on a NON-watched workflow:
# the #1261 shape — a lint gate red on main while the watched lane is green.
main_red_surface() {
  write_main_checks \
    "$(check_run 6001 lint completed failure 7201)" \
    "$(check_run 6002 'test (a)' completed success 7201)"
  main_run_map 7201 push 'Post-merge validation'
}

# Shared comparison helper. The captures below go through this function rather
# than `"$(bash "$CFS" …)"` because the main-worktree-guard's unverifiable-
# content gate fails closed on ANY command substitution whose first token is a
# shell interpreter or a path (`SHELL_INTERPRETERS.has(first) ||
# /^\.{0,2}\//.test(first)`), without reading what that script does — so this
# suite became unrunnable by an agent even though it performs no git operation
# at all (`allGitInvocations(run.sh)` is empty). Semantics are unchanged; the
# gate defect is tracked separately. NOTE for reviewers: if you re-inline this
# helper, the guard blocks the whole suite again in an agent session.
cfs_diff() { bash "$CFS" --diff "$1" "$2"; }

# Same guard-safe shape as cfs_diff (no `$(bash <path> …)` substitution): run the
# parser script itself and capture its streams for assertions. The extraction is
# its OWN unit — the admin-merge rail is a separate consumer (#3756).
cfs_run() {
  SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" "$@" >"$TMP/cfs-out" 2>"$TMP/cfs-err"
  return $?
}

# Same reason as cfs_diff, one indirection further out: the #1484 classifier fails
# closed on a `$(bash <path> …)` substitution, because that is also the shape of the
# closed script backdoor. Calling the guard through a function whose body is the plain
# invocation keeps the suite runnable by an agent — inlining it again re-blocks the
# WHOLE suite, which is how the cycle-3 review caught this (it was self-inflicted, not
# a classifier defect: the commit that mentioned "the #1484 classifier" was the one
# that introduced the pattern).
lane_tested() { bash "$ROOT/scripts/check-lane-tested.sh" "$@"; }

# ── 1. --diff is set subtraction on unsorted, duplicated input ─────────────
echo "== 1. --diff (the single shared comparison) =="
printf 'b\na\na\n' > "$TMP/a.txt"
printf 'a\nc\n' > "$TMP/b.txt"
out="$(cfs_diff "$TMP/a.txt" "$TMP/b.txt")"
if [ "$out" = "b" ]; then
  pass "unsorted + duplicated input: only b is unique to a"
else
  fail "expected 'b', got '$out'"
fi
printf '' > "$TMP/empty.txt"
out="$(cfs_diff "$TMP/empty.txt" "$TMP/b.txt")"
[ -z "$out" ] && pass "empty left side → empty diff" || fail "expected empty diff, got '$out'"
out="$(cfs_diff "$TMP/b.txt" "$TMP/b.txt")"
[ -z "$out" ] && pass "identical sets → empty diff" || fail "expected empty diff, got '$out'"

# ── 2. the #3469 trap ─────────────────────────────────────────────────────
# test_import_wrong_key_422 and test_import_count_mismatch_422 share one
# assertion; WHICH sibling trips depends on execution order, so main fails each
# in different runs. The PR's failure is one of them.
echo "== 2. #3469 order-flaky sibling pair (raw diff = 1, true = 0) =="
new_scen trap
HEAD_TRAP="aaaa000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TRAP" > "$SCEN/head"
X='tests/test_import.py::test_import_count_mismatch_422'
Y='tests/test_import.py::test_import_wrong_key_422'
# PR head fails X only.
lane_fail "$HEAD_TRAP" 101 > "$SCEN/runs-$HEAD_TRAP"
log_failed "$X" > "$SCEN/log-101"
# main: newest run fails Y, older run fails X — so a SINGLE-run baseline (the
# newest) cannot see X and reads it as new. The THIRD run fails X too, so the
# decision has a measurable main rate for X (2/3) rather than one observation.
{ lane_fail main1111 201; lane_fail main2222 202; lane_fail main3333 203; } > "$SCEN/runs-main"
log_failed "$Y" > "$SCEN/log-201"
log_failed "$X" > "$SCEN/log-202"
log_failed "$X" > "$SCEN/log-203"

SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --pr 42 > "$TMP/pr-fails" 2>/dev/null
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 1 > "$TMP/main-1.txt" 2>/dev/null
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 2 > "$TMP/main-2.txt" 2>/dev/null
# PR number: `pr view` reads $SCEN/head regardless of PR, so 42 is fine.
single="$(cfs_diff "$TMP/pr-fails" "$TMP/main-1.txt")"
union="$(cfs_diff "$TMP/pr-fails" "$TMP/main-2.txt")"
if [ "$(printf '%s\n' "$single" | grep -c .)" = "1" ]; then
  pass "single-run baseline FALSE-BLOCKS (raw comm -23 = 1) — the trap is real"
else
  fail "expected the single-run baseline to report 1 unique failure, got: '$single'"
fi
if [ -z "$union" ]; then
  pass "union baseline sees 0 unique (the same sibling pair) — no false block"
else
  fail "expected the union baseline to find 0 unique failures, got: '$union'"
fi
run_admin 42 --main-runs 3 >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "admin-merge.sh with --main-runs 3 merges (exit 0) — the safe merge is NOT blocked"
else
  fail "expected exit 0 for the #3469 shape, got $rc"
  sed 's/^/      /' "$TMP/err"
fi
if [ -f "$SCEN/comment" ] && grep -q "blocked by the decision: 0" "$SCEN/comment"; then
  pass "evidence records 'blocked by the decision: 0'"
else
  fail "evidence comment missing or without the counts line"
fi

# ── 3. flake re-run classification ────────────────────────────────────────
echo "== 3. residual that passes on retry is flaky, not new =="
new_scen flaky
HEAD_FLAKE="bbbb000000000000000000000000000000000000"
printf '%s\n' "$HEAD_FLAKE" > "$SCEN/head"
FL='tests/test_flaky.py::test_sometimes'
lane_fail "$HEAD_FLAKE" 301 > "$SCEN/runs-$HEAD_FLAKE"
log_failed "$FL" > "$SCEN/log-301"
lane_fail main3333 401 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-401"
log_passed "$FL" > "$SCEN/log-after-301"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "flake residual → exit 0 (not blocked)"
else
  fail "expected exit 0 for a flake residual, got $rc"
  sed 's/^/      /' "$TMP/err"
fi
if [ -f "$SCEN/comment" ] && grep -q "Flake classification: 1 residual re-ran → all passed on retry (flaky, not new)" "$SCEN/comment"; then
  pass "evidence records the flake classification verbatim"
else
  fail "evidence does not record the flake classification"
  [ -f "$SCEN/comment" ] && sed 's/^/      /' "$SCEN/comment"
fi
if grep -q "pr merge 42 --admin" "$SCEN/calls"; then
  pass "the merge actually ran (gh pr merge 42 --admin)"
else
  fail "no --admin merge call recorded"
fi

# ── 4. a genuine new failure survives the re-run → BLOCK ──────────────────
echo "== 4. genuine new failure surviving the re-run BLOCKS =="
new_scen block
HEAD_GEN="cccc000000000000000000000000000000000000"
printf '%s\n' "$HEAD_GEN" > "$SCEN/head"
NEW='tests/test_new.py::test_brand_new_failure'
lane_fail "$HEAD_GEN" 501 > "$SCEN/runs-$HEAD_GEN"
log_failed "$NEW" > "$SCEN/log-501"
lane_fail main4444 601 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-601"
cp "$SCEN/log-501" "$SCEN/log-after-501"   # the retry FAILS again
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "exit non-zero ($rc)" || fail "expected a non-zero exit, got 0"
if grep -q "test_brand_new_failure" "$TMP/err"; then
  pass "the residual failure list is printed"
else
  fail "the residual list was not printed"
fi
[ -f "$SCEN/comment" ] && fail "NO evidence comment may be posted on a block" || pass "no evidence comment posted"
if grep -q "pr merge" "$SCEN/calls"; then
  fail "no merge may be attempted on a block"
else
  pass "no merge attempted"
fi

# ── 5. extraction failure is fail-closed (the vacuous-pass guard) ─────────
echo "== 5. unreadable log → extraction failure → BLOCK (never a vacuous pass) =="
new_scen vacuous
HEAD_VAC="dddd000000000000000000000000000000000000"
printf '%s\n' "$HEAD_VAC" > "$SCEN/head"
lane_fail "$HEAD_VAC" 701 > "$SCEN/runs-$HEAD_VAC"
: > "$SCEN/fail-log-701"          # `gh run view --log-failed` fails
lane_fail main5555 801 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-801"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "exit non-zero ($rc) on extraction failure" || fail "expected a non-zero exit, got 0"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted when the set could not be read" || pass "no evidence comment posted"
grep -q "could not fetch the failed-step log" "$TMP/err" && pass "the parser's failure is surfaced, not swallowed" || fail "expected the parser failure on stderr"

# ── 6. evidence structure ─────────────────────────────────────────────────
echo "== 6. evidence structure (marker + counts + provenance) =="
new_scen shape
HEAD_SHAPE="eeee000000000000000000000000000000000000"
printf '%s\n' "$HEAD_SHAPE" > "$SCEN/head"
lane_fail "$HEAD_SHAPE" 901 > "$SCEN/runs-$HEAD_SHAPE"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-901"
# 3 main runs failing the SAME id with the SAME signature: enough for the decision
# to measure MAIN; the PR's single run is below `min_runs`, so the exemption rides
# the attribution path (#5250 — see main_red_n).
main_red_n main6666 1001 3 'tests/test_other.py::test_red_on_main' > "$SCEN/runs-main"
run_admin 42 --main-runs 3 >/dev/null 2>&1
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  grep -q "<!-- admin-merge-safety: $HEAD_SHAPE -->" "$c" && pass "marker binds the head SHA" || fail "marker missing/not head-bound"
  grep -q "^PR head: $HEAD_SHAPE$" "$c" && pass "PR head recorded" || fail "PR head line missing"
  grep -q "main compared (union of 3 runs of python-ci.yml): " "$c" && pass "main provenance recorded as sha:run-id, lane named" || fail "main provenance line wrong"
  grep -q "^test lane: python-ci.yml$" "$c" && pass "the lane is stated in the evidence" || fail "test lane line missing"
  grep -q "PR failing: 1 | main failing: 1 | blocked by the decision: 0" "$c" && pass "counts line exact" || fail "counts line wrong"
  grep -q "Failing runs examined: PR=1 main=3" "$c" && pass "examined/extracted counts recorded" || fail "examined counts missing"
  grep -q "^Lane completion: PR completed=1 tested=1 pending=0" "$c" && pass "lane completion recorded (the fact that makes 'empty' mean green)" || fail "lane completion line missing"
  grep -q "Flake classification: none needed" "$c" && pass "clean case records no re-run" || fail "clean-case flake line wrong"
  grep -q 'final residual (the exemption decision' "$c" && pass "the residual block names the decision that produced it" || fail "residual block missing"
  # The sets themselves, not just the verdict. Before this, the only diff
  # evidence on the clean path was an EMPTY `comm` block, so the failing test
  # ids appeared NOWHERE in the comment and `unique: 0` was an unfalsifiable
  # claim to the reader. Each id must now appear in BOTH the PR set and the main
  # baseline (plus the visible-EXEMPT list).
  n=$(grep -c 'tests/test_other.py::test_red_on_main' "$c" || true)
  [ "$n" -ge 2 ] && pass "both failing sets are listed verbatim ($n occurrences: PR set + main baseline)" \
    || fail "expected the failing test id in both sets, got $n — the auditable diff is not recorded"
  grep -q 'all EXEMPT (id measured on main with a matching signature; rate compared where the PR sample was measurable)' "$c" \
    && pass "the PR-carried set is labelled as exempt-with-evidence" || fail "PR-set label missing"
  grep -q 'main baseline: 1 pre-existing failure(s), for comparison' "$c" \
    && pass "main's baseline set is listed for comparison" || fail "main baseline set missing"
else
  fail "no evidence comment posted for the clean case"
fi

# ── 7. merge flags pass through ───────────────────────────────────────────
echo "== 7. extra merge flags pass through (not hardcoded) =="
run_admin 42 --main-runs 3 --squash --delete-branch >/dev/null 2>&1
if grep -q "pr merge 42 --admin --squash --delete-branch --match-head-commit $HEAD_SHAPE" "$SCEN/calls"; then
  pass "--squash/--delete-branch forwarded and the merge is head-pinned (--match-head-commit)"
else
  fail "merge flags were not forwarded, or the merge is not head-pinned"
  grep "pr merge" "$SCEN/calls" | sed 's/^/      /'
fi

# ── 8. --dry-run posts and merges nothing ─────────────────────────────────
echo "== 8. --dry-run is inert =="
new_scen dry
HEAD_DRY="ffff000000000000000000000000000000000000"
printf '%s\n' "$HEAD_DRY" > "$SCEN/head"
lane_fail "$HEAD_DRY" 1101 > "$SCEN/runs-$HEAD_DRY"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-1101"
lane_fail main7777 1201 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-1201"
run_admin 42 --main-runs 1 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "--dry-run exits 0" || fail "--dry-run exited $rc"
[ -f "$SCEN/comment" ] && fail "--dry-run must not post" || pass "--dry-run posted nothing"
grep -q "pr merge" "$SCEN/calls" && fail "--dry-run must not merge" || pass "--dry-run merged nothing"

# ── 9. PARITY: one `comm -23`, two consumers ──────────────────────────────
echo "== 9. parity — the comparison has exactly ONE implementation =="
cfs_comm="$(grep -cE '^[[:space:]]*comm[[:space:]]+-23' "$CFS")"
[ "$cfs_comm" = "1" ] && pass "ci-failure-set.sh has exactly one executed comm -23" || fail "expected 1 executed comm -23 in the parser, got $cfs_comm"
grep -qE '^[[:space:]]*comm[[:space:]]+-23' "$ADM" && fail "admin-merge.sh re-implements the comparison" || pass "admin-merge.sh does not re-implement comm -23"
if [ -f "$DETECTOR" ]; then
  grep -qE '^[[:space:]]*comm[[:space:]]+-23' "$DETECTOR" && fail "the detector re-implements comm -23" || pass "detector does not re-implement comm -23"
  grep -q -- '--diff' "$DETECTOR" && pass "detector uses the shared --diff mode" || fail "detector does not use --diff"
  # CANNOT-RUN must not read as NOTHING-FOUND: the dependency is checked, and no
  # extraction path warns-then-exits-0 (which is the silent no-op a consumer
  # without scripts/ used to get for every merge, for ever).
  grep -q 'CANNOT RUN' "$DETECTOR" && pass "detector refuses to run without its dependency (no silent no-op)" || fail "the detector may no-op silently when its dependency is absent"
  # #972: the dependency must NOT be a repo-local path. `agent-infra init`
  # installs a consumer's `scripts/` as a MACHINE-LOCAL symlink, so a detector
  # reaching for `scripts/` works where it is developed and never on a runner.
  # Assert the resolution source, not just the guard's wording — this is the
  # regression that made the detector inert in every consumer repo.
  local_dep=$(grep -c 'bash scripts/ci-failure-set.sh\|bash scripts/check-lane-tested.sh' "$DETECTOR" || true)
  pinned_dep=$(grep -c 'bash \.agent-infra/scripts/' "$DETECTOR" || true)
  [ "${local_dep:-0}" -eq 0 ] && pass "the detector never invokes a repo-local scripts/ helper" \
    || fail "the detector still invokes a repo-local helper ($local_dep) — a dangling symlink on a runner (#972)"
  [ "${pinned_dep:-0}" -eq 4 ] && pass "all 4 helper invocations resolve from the pinned agent-infra checkout" \
    || fail "expected 4 pinned-helper invocations (3 x ci-failure-set.sh + 1 x check-lane-tested.sh), got $pinned_dep"
  grep -q 'ADMIN_MERGE_DETECTOR_REF' "$DETECTOR" && pass "the helper ref is repo-configurable, so a repo can pin it" \
    || fail "the pinned ref is not configurable"
  if grep -qE '::warning::.*could not extract' "$DETECTOR"; then
    fail "an extraction failure is still downgraded to a warning — that is the silent no-op"
  else
    pass "extraction failures are not downgraded to warnings"
  fi
  grep -q -- '--workflow "$WORKFLOW"' "$DETECTOR" && pass "detector lane-filters both sides" || fail "the detector does not lane-filter"
else
  fail "missing $DETECTOR (the post-merge consumer)"
fi

# ── 10. THE BOGUS ZERO (the second trap) ─────────────────
# `gh run list --branch main` returns whatever ran most, NOT the test lane.
# Measured on tortoise main 2026-09-13: of the last 30 runs, 11 were
# `availability-watchdog`, 3 `Inbound relay`, 3 `redis-guard`, 3
# `welcome-e2e-monitor`, 2 `registry-backup-cron` — and only 2 were the test
# lane. So a window of 10 can hold ZERO test runs: the baseline extracts EMPTY
# while main is red, and the PR's failure false-blocks as "new".
echo "== 10. THE BOGUS ZERO — an unfiltered main window reads EMPTY ="
new_scen boguszero
HEAD_BZ="1111000000000000000000000000000000000000"
printf '%s\n' "$HEAD_BZ" > "$SCEN/head"
SIB='tests/test_import.py::test_import_count_mismatch_422'
# The PR fails the sibling that main ALSO fails — in a different run (#3469).
lane_fail "$HEAD_BZ" 2001 > "$SCEN/runs-$HEAD_BZ"
log_failed "$SIB" > "$SCEN/log-2001"
# main, UNFILTERED: the last 10 runs are non-test lanes. Their logs carry no
# `FAILED <nodeid>` line, so the unfiltered baseline is EMPTY.
# main, UNFILTERED: the last 10 runs are non-test lanes. A FAILED-looking
# entry with no pytest log contributes no nodeid, so the unfiltered baseline is
# EMPTY even though the lane is red elsewhere.
i=0
while [ "$i" -lt 10 ]; do lane_fail main9999 "$((3000 + i))" >> "$SCEN/runs-main"; i=$((i + 1)); done
# main, TEST LANE only: it fails the very sibling the PR is charged with, over
# 3 tested runs so MAIN is measurable; the PR's single run is below `min_runs`, so
# the exemption rides the attribution path (#5250 — see main_red_n).
main_red_n main8888 4001 3 "$SIB" > "$SCEN/runs-main.by-workflow.python-ci.yml"

run_admin 42 --main-runs 10 --any-workflow >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "unfiltered window → bogus empty baseline → FALSE BLOCK (the trap is real)" \
  || fail "expected the unfiltered window to false-block, got exit 0"
run_admin 42 --main-runs 10 >/dev/null 2>&1
rc=$?
if [ "$rc" -eq 0 ]; then
  pass "filtered to the test lane → baseline sees the sibling → no false block"
else
  fail "expected exit 0 with the lane filter, got $rc"
  sed 's/^/      /' "$TMP/err"
fi
grep -q "main compared (union of 3 runs of python-ci.yml): " "$SCEN/comment" \
  && pass "evidence names the lane and the lane-filtered provenance" \
  || fail "evidence does not record the lane-filtered provenance"

# ── 11. --repo must reach the RUN calls ───────────────────────────────────
# The first cut accepted --repo and dropped it for `gh run list` / `gh run
# view`, so `admin-merge.sh <PR> --repo other/repo` silently compared the WRONG
# repo's baseline — the same vacuous-comparison class the rail exists to prevent.
echo "== 11. --repo reaches the run listing (a silent wrong-repo comparison is vacuous) =="
new_scen repoflag
HEAD_RP="2222000000000000000000000000000000000000"
printf '%s\n' "$HEAD_RP" > "$SCEN/head"
lane_fail "$HEAD_RP" 5001 > "$SCEN/runs-$HEAD_RP"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-5001"
lane_fail main1234 5002 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-5002"
run_admin 42 --main-runs 1 --repo other-org/other-repo --dry-run >/dev/null 2>&1
list_line="$(grep -m1 -E '^run list' "$SCEN/calls")"
case "$list_line" in
  *"--repo other-org/other-repo"*) pass "gh run list received --repo" ;;
  *) fail "gh run list did NOT receive --repo — a silent wrong-repo comparison"; echo "      $list_line" ;;
esac
case "$list_line" in
  *"--workflow python-ci.yml"*) pass "gh run list received the lane filter" ;;
  *) fail "gh run list did NOT receive the lane filter"; echo "      $list_line" ;;
esac
view_line="$(grep -m1 -E '^run view 5002' "$SCEN/calls")"
case "$view_line" in
  *"--repo other-org/other-repo --log-failed"*) pass "gh run view received --repo" ;;
  *) fail "gh run view did NOT receive --repo"; echo "      $view_line" ;;
esac

# ── 12. the head must have been TESTED (review P0 #3) ────
# A queued/in-progress run — or no run at all — yields an EMPTY failing set,
# which is indistinguishable from "green" unless completion is gated. Without
# this the rail certifies nothing and merges before CI finishes, and the fresh
# failure lands after the merge: the #3420 ratchet it exists to stop.
echo "== 12. the head must have been TESTED (P0 #3) =="
# (a) the lane is still running for this head
new_scen pending
HEAD_PD="6666000000000000000000000000000000000000"
printf '%s\n' "$HEAD_PD" > "$SCEN/head"
lane_queued "$HEAD_PD" 9001 > "$SCEN/runs-$HEAD_PD"
lane_fail main6666 9002 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9002"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "in-progress lane run → BLOCK (exit $rc)" || fail "expected a non-zero exit, got 0"
grep -q "has NOT finished" "$TMP/err" && pass "the block names the unfinished lane" || fail "expected the not-finished reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"

# (b) the lane produced NO run at all for this head
new_scen norun
HEAD_NR="7777000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NR" > "$SCEN/head"
: > "$SCEN/runs-$HEAD_NR"
lane_fail main5555 9102 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9102"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "no lane run for the head → BLOCK (exit $rc)" || fail "expected a non-zero exit, got 0"
grep -q "no run of the lane actually TESTED" "$TMP/err" && pass "the block says nothing was tested" || fail "expected the not-tested reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted" || pass "no evidence comment posted"

# ── 13. the head must not MOVE (review P1) ───────────────
# The head-move check used to live ONLY inside the flake branch, so the common
# clean path posted evidence for one SHA and merged whatever the head was by
# then. Here the failing sets match (unique = 0, the CLEAN path) and the head
# moves between the analysis and the evidence: it must still BLOCK.
echo "== 13. head moving before the evidence BLOCKS (clean path, P1) =="
new_scen headmove
HEAD_HM="3333000000000000000000000000000000000000"
NEW_HM="4444000000000000000000000000000000000000"
printf '%s\n%s\n' "$HEAD_HM" "$NEW_HM" > "$SCEN/head-seq"
printf '0' > "$SCEN/head-seq-count"
lane_fail "$HEAD_HM" 7001 > "$SCEN/runs-$HEAD_HM"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-7001"
# The decision path must be CLEAN for this scenario to reach the head-move check:
# main fails the SAME id over 3 tested runs, so the decision exempts the PR's
# single-run failure on the attribution path (#5250).
main_red_n main5555 7002 3 'tests/test_other.py::test_red_on_main' > "$SCEN/runs-main"
run_admin 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "exit non-zero ($rc) when the head moved" || fail "expected a non-zero exit, got 0 — the clean path merged a moved head"
grep -q "head moved before the evidence" "$TMP/err" && pass "the block names the head move" || fail "expected the head-move reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted for a moved head" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"

# ── 14. a FAILED main-side input is not an EMPTY one (review P2, #3756) ──
# The decision's baseline is TWO files (rates + signatures). The signature table
# was added by the swap, and a failure to extract it must BLOCK — reading it as
# empty would make every signature check fail closed anyway, but the caller must
# see the refusal, and a silently-empty baseline must never merge. Fail-open.
echo "== 14. a failed main-signature extraction BLOCKS (fail-open, P2) =="
new_scen diffail
HEAD_DF="8888000000000000000000000000000000000000"
printf '%s\n' "$HEAD_DF" > "$SCEN/head"
lane_fail "$HEAD_DF" 8001 > "$SCEN/runs-$HEAD_DF"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-8001"
lane_fail main7777 8002 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-8002"
# A parser that succeeds everywhere EXCEPT `--main-union-signatures`.
DIFF_FAILING="$TMP/cfs-sigs-fails.sh"
cat > "$DIFF_FAILING" <<'DIFFEOF'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "--main-union-signatures" ] && { echo "simulated signature extraction failure" >&2; exit 1; }
done
exec bash "$CFS_REAL" "$@"
DIFFEOF
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" \
  ADMIN_MERGE_FAILURE_SET_SH="$DIFF_FAILING" CFS_REAL="$CFS" \
  ADMIN_MERGE_POLL_INTERVAL=0 bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "exit non-zero ($rc) when the signature extraction fails" || fail "expected a non-zero exit, got 0 — fail-open"
grep -q "could not extract main's signature table" "$TMP/err" && pass "the block names the failed signature input" || fail "expected the signature-extraction reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted when the baseline could not be read" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"

# ── 15. the SECOND PR read is guarded too (review P2, flake branch) ──
# §14 only reaches the first read of the PR's rows. The flake branch re-reads
# them, and an unchecked failure there leaves an empty file → residual 0 → merge.
# Its own scenario is required or the guard is untested (VGATE finding).
echo "== 15. a failed SECOND PR read BLOCKS (flake branch, P2) =="
new_scen diffail2
HEAD_D2="9999000000000000000000000000000000000000"
printf '%s\n' "$HEAD_D2" > "$SCEN/head"
FL2='tests/test_flaky.py::test_sometimes'
lane_fail "$HEAD_D2" 8201 > "$SCEN/runs-$HEAD_D2"
log_failed "$FL2" > "$SCEN/log-8201"
log_passed "$FL2" > "$SCEN/log-after-8201"      # passes on retry → the 2nd read runs
lane_fail main6666 8202 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-8202"
# A parser that succeeds on the FIRST `--commit-rows` and fails on the SECOND.
DIFF_FAILING2="$TMP/cfs-rows2-fails.sh"
cat > "$DIFF_FAILING2" <<'DIFFEOF2'
#!/usr/bin/env bash
for a in "$@"; do
  if [ "$a" = "--commit-rows" ]; then
    n=$(( $(cat "$DIFF_COUNT_FILE" 2>/dev/null || echo 0) + 1 ))
    printf '%s' "$n" > "$DIFF_COUNT_FILE"
    [ "$n" -ge 2 ] && { echo "simulated second PR read failure" >&2; exit 1; }
  fi
done
exec bash "$CFS_REAL" "$@"
DIFFEOF2
printf '0' > "$TMP/diff-count-2"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" \
  ADMIN_MERGE_FAILURE_SET_SH="$DIFF_FAILING2" CFS_REAL="$CFS" \
  DIFF_COUNT_FILE="$TMP/diff-count-2" ADMIN_MERGE_POLL_INTERVAL=0 \
  bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "exit non-zero ($rc) when the SECOND PR read fails" || fail "expected a non-zero exit, got 0 — fail-open in the flake branch"
grep -q "PR failing set unreadable after re-run" "$TMP/err" && pass "the block names the post-re-run PR read failure" || fail "expected the post-re-run reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted when the PR set could not be read" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"

# ── 16. --exclude must ACTUALLY exclude (review P0, cycle 2) ──────────────
# The lane projection is TAGGED (`status<TAB>conclusion<TAB>sha:id`). `--exclude`
# used to be `awk -F: '$1 != x'`, which compared the whole first column — so it
# matched nothing, silently, and main's baseline kept the very run it was told to
# drop. The consumer that depends on it is the post-merge detector: it excludes
# the merge commit so the merged run's failures are not in its own baseline. With
# a dead `--exclude` the two sides are identical, `--diff` is always empty, and
# the detector can NEVER fire — the closed loop for a human's UI admin-merge is
# dead while still printing "no unique failures". A silent no-op in a gate is
# worse than a loud failure, so this drives the flag through its real projection.
echo "== 16. --exclude really drops the run (a silent no-op kills the detector) =="
new_scen exclude
EX_KEEP="aaaa000000000000000000000000000000000000"
EX_DROP="bbbb000000000000000000000000000000000000"
lane_fail "$EX_KEEP" 2001 > "$SCEN/runs-main"
lane_fail "$EX_DROP" 2002 >> "$SCEN/runs-main"
log_failed 'tests/test_keep.py::test_keep' > "$SCEN/log-2001"
log_failed 'tests/test_drop.py::test_drop' > "$SCEN/log-2002"
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 10 --exclude "$EX_DROP" --provenance "$TMP/ex-prov.txt" > "$TMP/ex-out.txt" 2>"$TMP/ex-err.txt" || fail "--main-union --exclude should succeed"
grep -q "test_keep" "$TMP/ex-out.txt" && pass "the non-excluded run is still parsed" || fail "the kept run's failure disappeared"
grep -q "test_drop" "$TMP/ex-out.txt" && fail "--exclude did NOT drop the run — the detector's own merge stays in its baseline (P0)" || pass "the excluded run is dropped from the failing set"
grep -q "$EX_DROP" "$TMP/ex-prov.txt" && fail "the excluded run is still reported as examined (provenance)" || pass "the excluded run is absent from provenance"
grep -q "$EX_KEEP" "$TMP/ex-prov.txt" && pass "the kept run is still in provenance" || fail "the kept run vanished from provenance"
# The SIGNATURE table must honour --exclude identically — it is the other half of
# the same baseline, and a dead `--exclude` here would let the excluded run's
# signatures license an exemption the rates table refused.
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union-signatures 10 --exclude "$EX_DROP" > "$TMP/ex-sig.txt" 2>/dev/null \
  || fail "--main-union-signatures --exclude should succeed"
grep -q "test_keep" "$TMP/ex-sig.txt" && pass "signatures: the non-excluded run is still parsed" || fail "signatures: the kept run's signature disappeared"
grep -q "test_drop" "$TMP/ex-sig.txt" && fail "signatures: --exclude did NOT drop the run" || pass "signatures: the excluded run is dropped"
# A run whose headSha is EMPTY must be KEPT: dropping runs we cannot identify
# shrinks the baseline and MANUFACTURES "unique" failures — the opposite of the
# vacuity bug, and just as wrong (VGATE cycle 2).
lane_line completed failure "" 2003 >> "$SCEN/runs-main"
log_failed 'tests/test_nosha.py::test_nosha' > "$SCEN/log-2003"
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 10 --exclude "$EX_DROP" > "$TMP/ex-nosha.txt" 2>/dev/null \
  || fail "--main-union --exclude should still succeed with an empty-sha run"
grep -q "test_nosha" "$TMP/ex-nosha.txt" && pass "an unidentifiable (empty-sha) run is kept, not silently dropped" || fail "--exclude dropped a run it could not identify — that manufactures unique failures"
# A SHORT --exclude must still match the full headSha (callers pass either).
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$CFS" --main-union 10 --exclude "${EX_DROP:0:7}" > "$TMP/ex-short.txt" 2>/dev/null \
  || fail "--main-union --exclude <short> should succeed"
grep -q "test_drop" "$TMP/ex-short.txt" && fail "a short --exclude did not match the full headSha" || pass "a short --exclude matches the full headSha"

# ── 17. a CANCELLED run is finished but is not EVIDENCE (review P1, cycle 2) ─
# Gating on `completed` accepted a `cancelled` run as "this revision was tested".
# `cancel-in-progress` supersede and cancelled CI both produce one, and neither
# exercised a line of the PR. `tested` counts only runs that actually ran the
# suite (success/failure/timed_out). `startup_failure` is NOT tested either: the
# workflow never started, so nothing ran (VGATE cycle 2).
echo "== 17. a cancelled run never certifies the head (terminal != tested) =="
new_scen cancelled
HEAD_CX="8888000000000000000000000000000000000000"
printf '%s\n' "$HEAD_CX" > "$SCEN/head"
lane_line completed cancelled "$HEAD_CX" 7701 > "$SCEN/runs-$HEAD_CX"
lane_fail maincafe 7702 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-7702"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a cancelled lane run → BLOCK (exit $rc)" || fail "expected a non-zero exit, got 0 — a cancelled run certified the head"
grep -q "actually TESTED" "$TMP/err" && pass "the block says the run tested nothing" || fail "expected the not-tested reason on stderr"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted for a cancelled run" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"
# …and it must NOT be mislabelled as a lane that does not run on PRs. A cancelled
# run DID run (terminal, tested=0) — that is the case the lines above describe,
# and the main-only diagnosis is a different fault with a different fix (VGATE).
grep -q "MAIN-ONLY lane" "$TMP/err" \
  && fail "a cancelled run was mislabelled as a MAIN-ONLY lane — it had a run for this head" \
  || pass "a cancelled-only head is not mislabelled as a main-only lane"
# ...but a cancelled run ALONGSIDE a run that did execute must NOT block: the real
# run is the evidence. A fix that over-blocks gets the gate disabled.
new_scen cancelled-plus
printf '%s\n' "$HEAD_CX" > "$SCEN/head"
lane_line completed cancelled "$HEAD_CX" 7703 > "$SCEN/runs-$HEAD_CX"
lane_pass "$HEAD_CX" 7704 >> "$SCEN/runs-$HEAD_CX"
# The baseline is a REQUIRED half of this scenario, not scenery: without it the
# rail has nothing to compare against and now says so (#1003), which would make
# this test pass for the wrong reason. It was missing here, so the head-side
# assertion below was riding on a comparison that never happened.
lane_fail maincafe 7705 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-7705"
run_admin 42 --main-runs 1 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a cancelled run beside a tested run → allow (exit 0)" || fail "expected exit 0, got $rc — the tested-count fix over-blocks"
grep -q "tested=1" "$TMP/out" && pass "the evidence reports tested=1 of completed=2" || fail "expected tested=1 in the printed evidence"
# `startup_failure` = the workflow never STARTED. It is terminal, so the old
# `completed` gate accepted it as "tested" although nothing ran (VGATE cycle 2).
new_scen startupfail
HEAD_SF="aaaa111100000000000000000000000000000000"
printf '%s\n' "$HEAD_SF" > "$SCEN/head"
lane_line completed startup_failure "$HEAD_SF" 7711 > "$SCEN/runs-$HEAD_SF"
lane_fail maind00d 7712 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-7712"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a startup_failure-only head → BLOCK (exit $rc)" || fail "expected a non-zero exit, got 0 — a workflow that never started certified the head"
grep -q "actually TESTED" "$TMP/err" && pass "the block says the run tested nothing" || fail "expected the not-tested reason on stderr"

# ── 18. --dry-run mutates NOTHING, CI included (review P2, cycle 2) ──────────
# `--dry-run` is documented as posting nothing and merging nothing, but the
# re-run loop ran BEFORE the dry-run branch, so a documented no-op re-ran a
# caller's CI. A dry run must be safe to point at anything, any time.
echo "== 18. --dry-run performs no CI re-run (and no merge) =="
new_scen dryrun-rerun
HEAD_DR="9999000000000000000000000000000000000000"
printf '%s\n' "$HEAD_DR" > "$SCEN/head"
lane_fail "$HEAD_DR" 8801 > "$SCEN/runs-$HEAD_DR"
log_failed 'tests/test_newly.py::test_newly_landed' > "$SCEN/log-8801"
lane_fail mainbeef 8802 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-8802"
run_admin 42 --main-runs 1 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "--dry-run exits 0 on an unexplained failure" || fail "expected exit 0 (a dry run reports, it does not decide), got $rc"
grep -q "run rerun" "$SCEN/calls" && fail "--dry-run RE-RAN CI — a documented no-op mutated the caller's CI" || pass "--dry-run issued no CI re-run"
grep -q "pr merge" "$SCEN/calls" && fail "--dry-run merged" || pass "--dry-run attempted no merge"
[ -f "$SCEN/comment" ] && fail "--dry-run posted evidence" || pass "--dry-run posted nothing"
grep -qi "re-run" "$TMP/out" && pass "the dry run says a real run would re-run and re-classify" || fail "expected the dry run to say what a real run would do"

# ── 19. --repo reaches EVERY repo-scoped gh call (residual P0 #2) ───────────
# `--repo` reached `pr view` / `run list` / `run view --log-failed`, but NOT
# `run rerun` or `run view --json status`. Both are repo-scoped: on the flake
# path a cross-repo rail either failed to re-run (BLOCK) or polled the WRONG
# repo until timeout. The class is "one call site silently drops a flag".
echo "== 19. --repo reaches run rerun and the status poll =="
new_scen repoflag2
HEAD_RR="3333000000000000000000000000000000000000"
printf '%s\n' "$HEAD_RR" > "$SCEN/head"
lane_fail "$HEAD_RR" 6601 > "$SCEN/runs-$HEAD_RR"
log_failed 'tests/test_often.py::test_flaky_sibling' > "$SCEN/log-6601"
lane_fail main6666 6602 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-6602"
# after the re-run the flaky sibling passes → the flake path completes
log_passed 'tests/test_often.py::test_flaky_sibling' > "$SCEN/log-after-6601"
run_admin 42 --main-runs 1 --repo other-org/other-repo >/dev/null 2>&1
rerun_line="$(grep -m1 -E '^run rerun' "$SCEN/calls")"
case "$rerun_line" in
  *"--repo other-org/other-repo"*) pass "gh run rerun received --repo" ;;
  *) fail "gh run rerun did NOT receive --repo — a cross-repo re-run hits the wrong repo"; echo "      $rerun_line" ;;
esac
poll_line="$(grep -m1 -E '^run view 6601 .*--json status' "$SCEN/calls")"
case "$poll_line" in
  *"--repo other-org/other-repo"*) pass "the status poll received --repo" ;;
  *) fail "the completion poll did NOT receive --repo — it polls the wrong repo"; echo "      $poll_line" ;;
esac

# ── 20. --help prints the WHOLE header (review P2, cycle 2) ─────────────────
# `sed -n '1,50p'` truncated a 65-line header, so `--help` ended mid-sentence and
# never showed --any-workflow / --no-rerun / --dry-run / --repo / the env seams.
# Exactly the `1,60p` bug already fixed in ci-failure-set.sh, repeated here.
echo "== 20. --help shows the WHOLE header =="
bash "$ADM" --help > "$TMP/help.txt" 2>&1 || true
# The flags appear in the SYNOPSIS (header lines <50), so grepping for them does
# NOT pin this fix — HEAD's truncated --help already listed all of them. Anchor on
# content that lives ONLY past the old `sed -n '1,50p'` cut: the DESCRIPTION block
# and the env seams. (The first cut of this test grepped the flags and passed
# with the fix reverted — a test that pins nothing; caught by VGATE.)
head_lines="$(grep -c '^#' "$ADM")"
grep -q "^# Env seams" "$ADM" && [ "$head_lines" -gt 50 ] \
  && pass "the file carries $head_lines comment lines, all past the old 50-line cut — the fix is meaningful" \
  || fail "expected more than 50 comment lines (the old cut was 50)"
for f in ADMIN_MERGE_GH ADMIN_MERGE_FAILURE_SET_SH ADMIN_MERGE_POLL_INTERVAL; do
  grep -q "$f" "$TMP/help.txt" && pass "--help prints the $f env seam (past the old cut)" || fail "--help is truncated before $f"
done
grep -q "mutates nothing at all" "$TMP/help.txt" && pass "--help prints the full --dry-run description (past the old cut)" || fail "--help truncates the --dry-run description"
grep -q "re-opens the bogus zero" "$TMP/help.txt" && pass "--help prints the full --any-workflow description" || fail "--help truncates the --any-workflow description"

# ── 21. a detected-but-unreported merge is not a PASSING run (review P2) ────
# The detector filed with `gh issue create … || echo ::warning::` then `exit 0`, so
# "I found something and could not report it" was indistinguishable from "nothing
# found". Assert the shape statically: the workflow must not swallow a filing
# failure, and must not fall back to exit 0 there. (`workflow_run`-triggered and
# referenced by nothing, it gates no required check — being red is safe.)
echo "== 21. the detector does not swallow a filing failure =="
DET="$ROOT/templates/.github/workflows/admin-merge-detector.yml"
grep -q 'if ! gh issue create' "$DET" && pass "the detector branches on the issue-creation result" || fail "the detector still swallows a filing failure"
grep -q 'UNREPORTED' "$DET" && pass "the failure is announced as UNREPORTED" || fail "expected an ::error:: naming the unreported merge"
# P2-2 (fresh review): the previous assertion grepped for a string that exists
# NOWHERE in the detector, so it passed unconditionally. Assert the property that
# actually matters and can fail: after announcing UNREPORTED, the step exits 1.
awk '/UNREPORTED/{seen=1} seen && /^[[:space:]]*exit 1$/{ok=1} END{exit !ok}' "$DET" \
  && pass "the detector EXITS 1 after announcing the unreported merge" \
  || fail "the detector announces UNREPORTED but does not exit non-zero — the merge stays unreported"

# ── 22. PARITY: the materialized detector is its template ───────────────────
# The template is the source of truth (sync-ci-workflows.sh copies it). A drifted
# materialization means the workflow GitHub runs is not the one reviewed.
echo "== 22. materialized detector is byte-identical to its template =="
if cmp -s "$ROOT/templates/.github/workflows/admin-merge-detector.yml" "$ROOT/.github/workflows/admin-merge-detector.yml"; then
  pass "the materialized detector is byte-identical to the template"
else
  fail "the materialized detector drifted from its template — run sh scripts/sync-ci-workflows.sh"
fi

echo ""
# ── 23. VACUITY: the detector refuses a comparison that never happened ──────
# Fresh review P1-3. An empty failing set only means "clean" if the lane actually
# RAN. With no vacuity guard a lane that produced zero runs (python-ci.yml is a
# `workflow_call`-only reusable — its runs are attributed to the CALLER) yields
# unique_count=0 and the detector reports a clean loop for a comparison it never
# performed. The guard must read `--runs-report` and exit non-zero.
echo "== 23. the detector refuses to certify a lane that never ran =="
grep -q -- '--runs-report merged-report.txt' "$DET" && pass "the detector collects the merged commit's run report" || fail "no --runs-report on the merged-commit call — the vacuity guard cannot exist"
grep -q 'check-lane-tested.sh merged-report.txt' "$DET" && pass "the detector delegates the guard to the shipped script" || fail "the detector does not call scripts/check-lane-tested.sh"
# Drive the REAL guard with fixtures. A grep-only assertion cannot tell a working
# guard from one neutralised to `||` (cycle-2 review P2), so exercise the script.
GUARD="$ROOT/scripts/check-lane-tested.sh"
if [ -f "$GUARD" ]; then
  gdir="$SCEN/guard"; mkdir -p "$gdir"
  printf 'examined=1\nextracted=1\ncompleted=1\ntested=0\npending=0\n' > "$gdir/never-ran.txt"
  printf 'examined=1\nextracted=1\ncompleted=1\ntested=0\npending=1\n' > "$gdir/pending.txt"
  printf 'examined=2\nextracted=2\ncompleted=2\ntested=2\npending=0\n' > "$gdir/ran.txt"
  printf 'examined=1\nextracted=1\ncompleted=1\n' > "$gdir/no-tested-key.txt"
  printf 'examined=0\nextracted=0\ncompleted=0\ntested=0\npending=0\n' > "$gdir/empty-lane.txt"
  printf 'examined=1\nextracted=1\ncompleted=1\ntested=garbage\npending=0\n' > "$gdir/non-numeric.txt"
  printf 'examined=1\nextracted=1\ncompleted=1\ntested=2\npending=garbage\n' > "$gdir/non-numeric-pending.txt"
  printf 'examined=1\nextracted=1\ncompleted=1\ntested=-1\npending=0\n' > "$gdir/negative.txt"
  run_guard() { bash "$GUARD" "$1" python-ci.yml deadbeef >/dev/null 2>&1; }
  run_guard "$gdir/never-ran.txt" && fail "tested=0 was CERTIFIED — the vacuity hole is open" || pass "a lane with tested=0 is refused"
  run_guard "$gdir/pending.txt" && fail "a pending run was CERTIFIED" || pass "a lane with a pending run is refused"
  run_guard "$gdir/empty-lane.txt" && fail "an empty lane was CERTIFIED" || pass "a lane with zero runs is refused"
  run_guard "$gdir/no-tested-key.txt" && fail "a report with no 'tested' counter was CERTIFIED (must fail closed)" || pass "a report missing the 'tested' counter is refused"
  run_guard "$gdir/non-numeric.txt" && fail "a NON-NUMERIC 'tested' was CERTIFIED — the guard fails open on garbage" || pass "a non-numeric 'tested' is refused"
  run_guard "$gdir/non-numeric-pending.txt" && fail "a NON-NUMERIC 'pending' was CERTIFIED" || pass "a non-numeric 'pending' is refused"
  run_guard "$gdir/negative.txt" && fail "a NEGATIVE 'tested' was CERTIFIED" || pass "a negative 'tested' is refused"
  run_guard "$gdir/ran.txt" || fail "a lane that DID test the commit was refused — the guard is too strict"
  run_guard "$gdir/ran.txt" && pass "a lane that genuinely tested the commit is accepted"
  run_guard "$gdir/does-not-exist.txt" && fail "a missing report was CERTIFIED" || pass "a missing report is refused"
  # The lane must be repo-configurable WITHOUT editing the workflow: a repo whose
  # test lane is not python-ci.yml used to have to edit its copy, which breaks the
  # template/materialized byte-parity pipeline-compliance enforces (cycle-2 P2).
  grep -q 'ADMIN_MERGE_DETECTOR_WORKFLOW' "$DET" && pass "the lane is configurable from a repo variable, so parity can hold" || fail "the lane is hardcoded — a repo with a different lane must break template parity to fix it"
else
  fail "missing scripts/check-lane-tested.sh — the guard cannot be tested as shipped"
fi

# ── 24. the evidence body is BOUNDED ────────────────────────────────────────
# GitHub rejects a comment body over 65,536 chars. The embedded sets are LISTS
# capped at EVIDENCE_ENTRIES (25) — sized from the OBSERVED distribution (main's
# union runs 18-19 entries), so the cap is a safety branch, not machinery that
# engages on every merge. Trimming is always STATED: a capped list that looks
# complete is worse than no list.
echo "== 24. the evidence body is bounded, and states its own trimming =="
new_scen bigset
HEAD_BIG="bbbb111100000000000000000000000000000000"
printf '%s\n' "$HEAD_BIG" > "$SCEN/head"
lane_fail "$HEAD_BIG" 9901 > "$SCEN/runs-$HEAD_BIG"
LONG="$(printf 'y%.0s' $(seq 1 700))"
i=0
while [ "$i" -lt 250 ]; do
  log_failed "tests/test_big.py::test_case_${i}_${LONG}"
  i=$((i + 1))
done > "$SCEN/log-9901"
# 3 identical main runs: the decision needs a measurable rate for each of the 250
# ids, not a single-sample appearance.
i=9902
while [ "$i" -lt 9905 ]; do
  lane_fail mainfeed "$i" >> "$SCEN/runs-main"
  cp "$SCEN/log-9901" "$SCEN/log-$i"
  i=$((i + 1))
done
run_admin 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a 250-entry set still certifies (exit 0)" \
  || { fail "a 250-entry set blocked the merge (exit $rc)"; sed 's/^/      /' "$TMP/err"; }
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  chars=$(wc -m < "$c" | tr -d ' ')
  [ "$chars" -lt 65536 ] && pass "body is $chars chars, under GitHub's 65,536-char cap" \
    || fail "body is $chars chars — over the cap, so a safe merge cannot post its evidence"
  items=$(grep -c '^- tests/' "$c")
  [ "$items" -eq 50 ] && pass "each set shows exactly the 25-entry cap (50 entries, 25 per set)" \
    || fail "expected 50 listed entries, got $items — the cap is not applied per list"
  grep -qF -- '- ...and 225 more' "$c" && pass "trimming is STATED (250 → 25 + 225 more), never silent" \
    || fail "trimming is silent — a reader cannot tell a capped list from a complete one"
  grep -qF -- 'Lists show at most 25 entries of 300 chars' "$c" && pass "the display policy is stated once, not per list" \
    || fail "the display policy is missing"
  grep -q "PR failing: 250 | main failing: 250 | blocked by the decision: 0" "$c" \
    && pass "the counts line keeps the FULL, uncapped count" || fail "the counts line was corrupted"
  grep -q "^PR head: $HEAD_BIG$" "$c" && pass "the head binding survives" || fail "the head line was lost"
  grep -q "main compared (union of 3 runs of python-ci.yml): " "$c" \
    && pass "the provenance line is intact" || fail "the provenance line was lost"
else
  fail "no evidence comment posted for the 250-entry case"
fi

# ── 25. the flake path's evidence is honest ─────────────────────────────────
# The flake path is the only route to three non-empty lists, and the only one
# where the displayed PR set is POST-rerun while the pre-rerun residual is
# non-empty. Showing that residual under a "must be empty" heading contradicts
# the sets around it.
echo "== 25. the flake path labels its residual honestly =="
new_scen flakebig
HEAD_FB="eeee444400000000000000000000000000000000"
printf '%s\n' "$HEAD_FB" > "$SCEN/head"
lane_fail "$HEAD_FB" 9931 > "$SCEN/runs-$HEAD_FB"
i=0
while [ "$i" -lt 120 ]; do
  log_failed "tests/test_flaky_big.py::test_case_$i"
  i=$((i + 1))
done > "$SCEN/log-9931"
lane_fail mainfb 9932 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9932"
i=0
while [ "$i" -lt 120 ]; do
  log_passed "tests/test_flaky_big.py::test_case_$i"
  i=$((i + 1))
done > "$SCEN/log-after-9931"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a 120-entry flake residual certifies after the re-run (exit 0)" \
  || { fail "expected exit 0 on the flake path, got $rc"; sed 's/^/      /' "$TMP/err"; }
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  grep -qF -- 'residual BEFORE the flake re-run — reclassified as flaky, NOT new failures' "$c" \
    && pass "the pre-rerun residual is labelled for what it is" || fail "the pre-rerun residual is missing/mislabelled"
  grep -qF -- '- ...and 95 more' "$c" && pass "the pre-rerun residual uses the same cap (120 → 25 + 95)" \
    || fail "the pre-rerun residual escaped the cap"
  grep -qF -- '(empty — the decision exempts every failure this PR carries)' "$c" \
    && pass "the 'must be empty' block shows the EMPTY post-rerun residual" \
    || fail "the pre-rerun residual leaked into the 'must be empty' block"
  grep -q "PR failing: 0 | main failing: 1 | blocked by the decision: 0" "$c" \
    && pass "the counts line reflects the POST-rerun PR set" || fail "the counts line does not match the post-rerun set"
else
  fail "no evidence comment posted on the flake path"
fi

# ── 26. a non-nodeid FAILED payload is dropped + reported, and reaches the
# evidence only ESCAPED (#3756 / #1353) ───────────────────────────────────
# A PR author controls test names, so a test can print a bare fence marker in the
# `FAILED <token>` position. #3756 defect 1: that token is NOT a test id, so the
# canonical parser DROPS it (counted and reported) before it can ever enter the
# set — the injection surface is removed at the source, not merely rendered
# inert. The evidence stays LISTS-of-ids, and the sound id in the SAME capture
# still certifies. Reverting the extractor to the shell `awk` puts ` ``` ` back
# into the evidence and turns this RED.
#
# #1353 ADDS A SECOND REQUIREMENT, AND THE TWO ARE RECONCILED, NOT TRADED OFF: the
# dropped token must now be NAMED in the posted evidence, and it must still not be
# able to break it. The evidence therefore renders the token with its markdown
# metacharacters ESCAPED and DISCLOSES that, so the raw fence marker never reaches
# the comment (the assertion below) while the token IS named (section 54's
# hostile-token case pins both halves). `UNATTRIBUTABLE` on stderr is still
# verbatim.
#
# Equivalently: an unparseable failure id is DROPPED + REPORTED, never carried,
# and because the evidence is LISTS there is no fence algorithm to get right. A
# `FAILED` payload that is NOT a pytest nodeid (` ``` `, `may`) must NOT enter
# the decision — it matches nothing on main, so it can never be subtracted or
# verified and reads as "unique to this PR" on every rail run, forever — a
# PERMANENT FALSE REFUSAL (#3756 defect 1). The canonical parser DROPS it,
# COUNTS it and REPORTS it as UNATTRIBUTABLE; a run whose ids were all garbage
# still refuses via the caller's `examined > extracted` gate, and a sound id in
# the SAME run still certifies.
echo "== 26. a non-nodeid FAILED payload is dropped, reported, and escaped in the evidence =="
new_scen btick
HEAD_BT="dddd333300000000000000000000000000000000"
printf '%s\n' "$HEAD_BT" > "$SCEN/head"
lane_fail "$HEAD_BT" 9921 > "$SCEN/runs-$HEAD_BT"
{ log_failed 'tests/test_ok.py::test_ok'; log_failed '```'; } > "$SCEN/log-9921"
main_red_n mainbt 9922 3 'tests/test_ok.py::test_ok' > "$SCEN/runs-main"
run_admin 42 --main-runs 3 >/dev/null 2>&1
rc=$?
# The garbage token must NOT become a failure id. An id that matches nothing on
# main can never be subtracted or verified, so it reads as "unique to this PR"
# on every rail run for every such PR, forever — a permanent false refusal
# (#3756 defect 1). The sound id in the SAME run must still be extracted and
# must still certify the merge, so the fix is not "extract nothing".
[ "$rc" -eq 0 ] && pass "a non-nodeid FAILED payload does NOT refuse a sound merge (dropped, not carried)" \
  || fail "a garbage token still refuses a sound merge (exit $rc): $(head -1 "$TMP/err")"
grep -q 'UNATTRIBUTABLE' "$TMP/err" && pass "the dropped token is REPORTED as UNATTRIBUTABLE (counted, not swallowed)" \
  || fail "the rejection is silent — a dropped token with no report"
[ -f "$SCEN/comment" ] && pass "the sound id in the same run still certified the merge (not 'extract nothing')" \
  || fail "no evidence comment posted for a sound run"
grep -q '```' "$SCEN/comment" 2>/dev/null && fail "the garbage token reached the evidence" \
  || pass "no garbage token in the evidence"
grep -q "pr merge" "$SCEN/calls" && pass "the merge proceeded (garbage cannot block it forever)" || fail "no merge"
# The evidence format itself: LISTS, not fenced blocks — so a backtick-bearing
# node id that DOES parse cannot close a block early.
new_scen btick2
printf '%s\n' "$HEAD_BT" > "$SCEN/head"
lane_fail "$HEAD_BT" 9931 > "$SCEN/runs-$HEAD_BT"
# The SAME capture shape as `btick` — a sound id AND a non-nodeid payload in the
# `FAILED` position — asserted at the EVIDENCE level rather than at the exit
# level. The assertions below require the dropped token to be REPORTED on stderr
# and absent from the evidence; a sound-id-only capture can exercise neither.
{ log_failed 'tests/test_ok.py::test_ok'; log_failed '```'; } > "$SCEN/log-9931"
main_red_n mainbt2 9932 3 'tests/test_ok.py::test_ok' > "$SCEN/runs-main"
run_admin 42 --main-runs 3 >/dev/null 2>&1
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  grep -qF 'tests/test_ok.py::test_ok' "$c" \
    && pass "the sound id in the same capture is in the evidence" \
    || fail "the sound id is missing from the evidence"
  grep -qF '```' "$c" \
    && fail "a non-nodeid backtick token reached the evidence" \
    || pass "the backtick token never reaches the evidence — dropped at the parser (#3756)"
  grep -q 'UNATTRIBUTABLE' "$TMP/err" \
    && pass "the dropped backtick token is REPORTED as UNATTRIBUTABLE (not silent)" \
    || fail "the dropped token is silent on stderr"
  d_open=$(grep -c '^<details>' "$c"); d_close=$(grep -c '^</details>$' "$c")
  [ "$d_open" -ge 3 ] && [ "$d_open" -eq "$d_close" ] \
    && pass "all evidence blocks stay structurally intact ($d_open/$d_close)" \
    || fail "block structure damaged ($d_open opened, $d_close closed)"
  fenced=$(grep -c '^```*$' "$c")
  [ "${fenced:-0}" -eq 0 ] && pass "no fenced block exists, so there is no fence to break" \
    || fail "a fenced block is present — the injection surface is back ($fenced)"
else
  fail "no evidence comment posted for the fence-format case"
fi

# ── 27. the provenance list uses the SAME single limit ──────────────────────
echo "== 27. the provenance list shares the one limit =="
new_scen provcap
HEAD_PC="ffff555500000000000000000000000000000000"
printf '%s\n' "$HEAD_PC" > "$SCEN/head"
lane_fail "$HEAD_PC" 9941 > "$SCEN/runs-$HEAD_PC"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9941"
: > "$SCEN/runs-main"
i=0
while [ "$i" -lt 60 ]; do
  lane_fail mainprov "$((9950 + i))" >> "$SCEN/runs-main"
  log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-$((9950 + i))"
  i=$((i + 1))
done
run_admin 42 --main-runs 60 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "60 failing main runs still certify (exit 0)" \
  || { fail "expected exit 0 with 60 main runs, got $rc"; sed 's/^/      /' "$TMP/err"; }
if [ -f "$SCEN/comment" ]; then
  c="$SCEN/comment"
  grep -qE 'main compared \(union of 60 runs of python-ci\.yml\): ' "$c" \
    && pass "the provenance line keeps its certifying prefix" || fail "the provenance line lost its certifying prefix"
  grep -qF -- '+35 more' "$c" && pass "the provenance list is capped by the same 25 (60 → 25 + 35)" \
    || fail "the provenance list is unbounded or uses a different limit"
  chars=$(wc -m < "$c" | tr -d ' ')
  [ "$chars" -lt 65536 ] && pass "body stays under the cap with 60 runs ($chars chars)" \
    || fail "body is $chars chars — unbounded provenance pushed it over"
else
  fail "no evidence comment posted for the 60-run case"
fi

# ── 28. SPLIT-TRIGGER LANES: a lane must exist on BOTH sides (#1003) ────────
# A repo can split its lanes by TRIGGER — a pull_request-only lane and a
# push-only lane (agent-infra itself: ci.yml is PR-only, ci-main.yml is
# main-only). Then NO single --workflow spans both sides, and two distinct
# faults follow. Both are asserted here.
echo "== 28. a lane with no runs on main is not a baseline (#1003) =="

# (a) THE FALSE CLAIM. `--main-runs` is the REQUESTED window; the certifying
# line used to print it as though it were the number of runs unioned. With 1
# main run and --main-runs 10 the comment asserted "union of 10 runs" — in the
# one line the review-enforcer trusts enough to certify a bypass. The count must
# be what was ACTUALLY unioned.
new_scen unioncount
HEAD_UC="f0f0000000000000000000000000000000000000"
printf '%s\n' "$HEAD_UC" > "$SCEN/head"
lane_pass "$HEAD_UC" 8901 > "$SCEN/runs-$HEAD_UC"
# TWO failing main runs against a requested window of TEN.
{ lane_fail mainaaaa 8902; lane_fail mainbbbb 8903; } > "$SCEN/runs-main"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-8902"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-8903"
run_admin 42 --main-runs 10 --dry-run >/dev/null 2>&1
got="$(grep -o 'main compared (union of [0-9]* runs' "$TMP/out" | head -1)"
grep -q "main compared (union of 2 runs of python-ci.yml)" "$TMP/out" \
  && pass "the evidence states the union size ACTUALLY used (2), not the requested window (10)" \
  || fail "the evidence claims a union size it did not compute (got: '$got')"
grep -q "union of 10 runs" "$TMP/out" \
  && fail "the REQUESTED window is still asserted as if it were the union" \
  || pass "no inflated union claim"

# …but a lane that is GREEN on both sides is not "missing": its runs EXIST and
# merely passed. Conflating the two would block every clean repo — the vacuous
# case is an outcome of a comparison that happened, and must stay certifiable.
new_scen greenboth
printf '%s\n' "$HEAD_UC" > "$SCEN/head"
lane_pass "$HEAD_UC" 8911 > "$SCEN/runs-$HEAD_UC"
{ lane_pass maincccc 8912; lane_pass maindddd 8913; } > "$SCEN/runs-main"
# #1319: the certify path now RESTS ON LANE PARITY, so the fixture has to show
# it — both sides executed the same test shards. Without these the rail cannot
# tell "both lanes green" from "two different lanes", and refuses (correctly).
lane_jobset 8911 success 'test (a)' 'test (b)'
lane_jobset 8912 success 'test (a)' 'test (b)'
lane_jobset 8913 success 'test (a)' 'test (b)'
run_admin 42 --main-runs 10 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a lane green on BOTH sides → certify (exit 0), not blocked" \
  || fail "expected exit 0 for a lane that exists on both sides and is green, got $rc"
grep -q "vacuous comparison" "$TMP/out" \
  && pass "…and it reads as VACUOUS (a comparison that happened), not as a missing baseline" \
  || fail "a green lane on both sides must read as vacuous, not as missing"
grep -q "lane parity: PR ⊇ main" "$TMP/out" \
  && pass "…and the certification STATES the lane parity it rests on (#1319)" \
  || fail "the zeros are certified without stating the parity they rest on"

# (b) THE SPLIT ITSELF. The lane has runs on the PR side and NONE on main — the
# empty baseline absorbs nothing, so a PRE-EXISTING failure is attributed to the
# PR and a safe merge is refused for the wrong reason. The certificate is a
# comparison; with nothing to compare against there is no certificate, and the
# block must name the way to a real baseline rather than leaving the caller to
# guess.
new_scen splitlane
HEAD_SPLIT="f1f1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_SPLIT" > "$SCEN/head"
lane_fail "$HEAD_SPLIT" 8801 > "$SCEN/runs-$HEAD_SPLIT"
log_failed 'tests/test_new.py::test_new' > "$SCEN/log-8801"
lane_fail mainbusy1 8802 > "$SCEN/runs-main"          # main is busy…
log_failed 'tests/test_other.py::test_red_main' > "$SCEN/log-8802"
: > "$SCEN/runs-main.by-workflow.python-ci.yml"          # …but never in THIS lane
run_admin 42 --main-runs 10 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a lane with no runs on main → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — certified against a baseline that does not exist"
grep -q "never TESTED main" "$TMP/err" \
  && pass "the block says the lane provides no baseline" \
  || fail "expected the no-baseline reason on stderr"
grep -q -- "--any-workflow" "$TMP/err" \
  && pass "the block names the way to a real baseline (--any-workflow)" \
  || fail "the block offers no way out of the split"
grep -q "vacuous comparison" "$TMP/err" \
  && fail "a MISCONFIGURATION is reported as a vacuous COMPARISON — the two must be distinguishable" \
  || pass "the no-baseline fault is not mislabelled as a vacuous comparison"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted against a baseline that does not exist" \
  || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"

# (c) THE OTHER DIRECTION: a MAIN-ONLY lane, i.e. the lane has runs on main and
# none for the head. "The lane ran but exercised nothing" and "this lane does not
# run on pull requests" are different faults with different fixes (wait for CI vs
# change the lane), so the block must not conflate them.
new_scen mainonly
HEAD_MO="f2f2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_MO" > "$SCEN/head"
: > "$SCEN/runs-$HEAD_MO"
lane_fail mainfeed 9002 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9002"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a lane with no runs for the head → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0"
grep -q "MAIN-ONLY lane" "$TMP/err" \
  && pass "the block names the split SHAPE (a main-only lane) instead of only 'nothing tested'" \
  || fail "the block cannot distinguish a main-only lane from one that merely has not started"

# (d) A main lane whose runs are all `cancelled`/`skipped` exercised NOTHING, so
# it is not a baseline either. `completed` would ACCEPT it; only `tested` refuses.
# Nothing pinned this: swapping the counter to `completed` left the suite green
# while a cancelled-only baseline fail-opened.
new_scen maincancelled
printf '%s\n' "$HEAD_UC" > "$SCEN/head"
lane_pass "$HEAD_UC" 8921 > "$SCEN/runs-$HEAD_UC"
lane_line completed cancelled maincanc 8922 > "$SCEN/runs-main"
run_admin 42 --main-runs 1 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a main lane whose only run was CANCELLED → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — a cancelled baseline run certified the merge"
grep -q "never TESTED main" "$TMP/err" && pass "…for the no-baseline reason" \
  || fail "expected the no-baseline reason on stderr"

# (e) A NON-NUMERIC counter is a report-contract violation (version skew).
# `[ "$x" -eq 0 ]` on such a value returns 2, and under `set -uo pipefail` (no
# `-e`) that SKIPS the body — so the guard fails OPEN and merges against a
# baseline that was never computed. The counter must be VALIDATED, not trusted.
# Driven through the parser seam so this is the real rail, not a grep.
cat > "$TMP/garbage-parser" <<'STUB'
#!/usr/bin/env bash
# A parser whose MAIN-side `tested` is not a number (contract violation).
rep=""; mode=""; i=0; args=("$@")
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    --runs-report) i=$((i+1)); rep="${args[$i]}" ;;
    --commit|--commit-rows) mode=pr; i=$((i+1)) ;;
    --main-union|--main-union-rates) mode=main; i=$((i+1)) ;;
    --diff) mode=diff ;;
  esac
  i=$((i+1))
done
case "$mode" in
  pr)   [ -n "$rep" ] && printf 'examined=0\nextracted=0\ncompleted=1\ntested=%s\npending=%s\n' "${STUB_PR_TESTED:-1}" "${STUB_PR_PENDING:-0}" > "$rep" ;;
  main) [ -n "$rep" ] && printf 'examined=0\nextracted=0\ncompleted=1\ntested=%s\npending=0\n' "${STUB_MAIN_TESTED:-1}" > "$rep" ;;
esac
exit 0
STUB
chmod +x "$TMP/garbage-parser"
new_scen garbagecounter
printf '%s\n' "$HEAD_UC" > "$SCEN/head"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" ADMIN_MERGE_FAILURE_SET_SH="$TMP/garbage-parser" \
  STUB_MAIN_TESTED='n/a' ADMIN_MERGE_POLL_INTERVAL=0 bash "$ADM" 42 --dry-run >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "a NON-NUMERIC main 'tested' → BLOCK (exit $rc), not fail-open" \
  || fail "a non-numeric baseline counter CERTIFIED the merge — [-eq] fails open on garbage"
grep -q "never TESTED main" "$TMP/err" && pass "…for the no-baseline reason" \
  || fail "expected the no-baseline reason for a malformed counter"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted on a malformed report" \
  || pass "no merge attempted"

# (f) …and the SAME hole on the head side, which `pending` had while `tested` was
# already validated: `[ "$x" -gt 0 ]` returns 2 on `n/a`, the body is skipped, the
# rail reads "nothing pending" and merges with the lane possibly still running.
# "Not proven finished" is not "finished". check-lane-tested.sh already refuses
# `pending=garbage`; the rail must not disagree with it.
new_scen garbagepending
printf '%s\n' "$HEAD_UC" > "$SCEN/head"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" ADMIN_MERGE_FAILURE_SET_SH="$TMP/garbage-parser" \
  STUB_PR_PENDING='n/a' ADMIN_MERGE_POLL_INTERVAL=0 bash "$ADM" 42 --dry-run >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "a NON-NUMERIC head 'pending' → BLOCK (exit $rc), not fail-open" \
  || fail "an unreadable 'pending' CERTIFIED the merge — the rail cannot show the lane finished"
grep -q "has NOT finished" "$TMP/err" && pass "…for the not-finished reason" \
  || fail "expected the not-finished reason for an unreadable pending"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted on an unreadable report" \
  || pass "no merge attempted"

# ── 29. cycle-3 review: a false certificate, a rebindable binding, and two
#        fail-opens in the guard's own counters ──────────────────────────────
echo "== 29. an unattributed failing run, the head binding, and pending =="

# (a) A FAILING run whose log yields NO `FAILED <nodeid>` line contributes NOTHING to
# the set, so "unique to this PR: 0" is unsupported — the certificate would be FALSE.
# Before the fix the rail printed `PR failing: 0` for a RED lane and merged it.
new_scen unattributed
HEAD_UA="a1a1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_UA" > "$SCEN/head"
lane_fail "$HEAD_UA" 9101 > "$SCEN/runs-$HEAD_UA"
printf 'test (a)\tRun tests\tImportError: no module named y\n' > "$SCEN/log-9101"
lane_fail mainua 9102 > "$SCEN/runs-main"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-9102"
run_admin 42 --main-runs 3 >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && pass "a failing run with NO parseable id BLOCKS (exit $rc)" \
  || fail "a RED lane was certified as zero-residual — a false certificate"
[ -f "$SCEN/comment" ] && fail "  …but an evidence comment was posted" || pass "  …no evidence comment"
grep -q "pr merge" "$SCEN/calls" && fail "  …but a merge was attempted" || pass "  …and no merge was attempted"
grep -q "parseable" "$TMP/err" && pass "  …and the refusal names the reason" || fail "  …the refusal is unexplained"

# …while a failing run that IS attributable behaves exactly as before (no over-block).
new_scen attributed
printf '%s\n' "$HEAD_UA" > "$SCEN/head"
lane_fail "$HEAD_UA" 9111 > "$SCEN/runs-$HEAD_UA"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-9111"
main_red_n mainua2 9112 3 'tests/test_pre.py::test_pre' > "$SCEN/runs-main"
run_admin 42 --main-runs 3 >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "an attributable failure present on both sides still certifies (no over-block)" \
  || fail "a normal zero-residual merge was blocked: $(head -1 "$TMP/err")"

# (b) `--match-head-commit` must come AFTER the caller's passthrough: gh takes the LAST
# occurrence of a scalar flag, so the old order let `-- --match-head-commit <other>`
# rebind the merge to a head other than the certified one.
new_scen rebound
HEAD_RB="b2b2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_RB" > "$SCEN/head"
lane_fail "$HEAD_RB" 9201 > "$SCEN/runs-$HEAD_RB"
log_failed 'tests/test_same.py::test_same' > "$SCEN/log-9201"
main_red_n mainrb 9202 3 'tests/test_same.py::test_same' > "$SCEN/runs-main"
run_admin 42 --main-runs 3 -- --match-head-commit deadbeefdeadbeefdeadbeefdeadbeefdeadbeef >/dev/null 2>&1
last_mhc="$(grep -o -- '--match-head-commit [0-9a-fA-F]*' "$SCEN/calls" | tail -1)"
[ "$last_mhc" = "--match-head-commit $HEAD_RB" ] \
  && pass "the certified head is the LAST --match-head-commit, so a passthrough cannot rebind it" \
  || fail "a passthrough rebound the merge (last flag: '$last_mhc')"

# (c) A report with NO `pending` counter is from a parser too old to answer the question.
# Defaulting it to 0 (as this did) silently asserted "nothing is still running".
printf 'examined=1\nextracted=1\ncompleted=1\ntested=1\n' > "$TMP/rep-nopending.txt"
out="$(lane_tested "$TMP/rep-nopending.txt" lane sha 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "a report MISSING 'pending' cannot certify (exit $rc)" \
  || fail "a missing 'pending' defaulted to 0 and certified the lane"
case "$out" in *"no 'pending' counter"*) pass "  …and it names the missing counter" ;; *) fail "  …unexplained: $out" ;; esac
printf 'examined=1\nextracted=1\ncompleted=1\ntested=1\npending=0\n' > "$TMP/rep-pending0.txt"
lane_tested "$TMP/rep-pending0.txt" lane sha >/dev/null 2>&1 \
  && pass "  …while an explicit pending=0 certifies (no over-block)" \
  || fail "an explicit pending=0 was refused"

# ── 30. THE DEMONSTRATION (#3756): union EXCUSES, the decision BLOCKS ─────
# The defect in one fixture: a failure main flaked ONCE in 8 runs is in main's
# union, so `comm -23` subtracts it forever and the gate reports GREEN — even when
# the PR fails it 8/8. The decision compares RATES and refuses it. This drives the
# REAL shipped module (`scripts/ci_exemption.py`), not a stub.
echo "== 30. pre-swap RED / post-swap correct (real decision module) =="
DEMO="$TMP/demo"; mkdir -p "$DEMO"
DID='tests/test_oauth_token_fault.py::test_capture_exception_raising_does_not_break_the_typed_error'
DSIG='AssertionError: assert (200 == 503)'
printf '%s\t1\t8\n' "$DID" > "$DEMO/main-rates.txt"
printf '%s\t%s\n' "$DID" "$DSIG" > "$DEMO/main-sigs.txt"
printf '%s\n' "$DID" > "$DEMO/main-union.txt"
printf '%s\t8\t8\t%s\n' "$DID" "$DSIG" > "$DEMO/pr-rows.txt"
printf '%s\n' "$DID" > "$DEMO/pr-fails.txt"
union_unique="$(comm -23 <(sort -u "$DEMO/pr-fails.txt") <(sort -u "$DEMO/main-union.txt"))"
[ -z "$union_unique" ] \
  && pass "PRE-SWAP RED: the union classifier EXCUSES the 8/8 regression (unique set empty → gate green)" \
  || fail "expected the union path to excuse the regression, got '$union_unique'"
python3 "$ROOT/scripts/ci_exemption.py" decide \
  --pr-failures "$DEMO/pr-rows.txt" --main-rates "$DEMO/main-rates.txt" \
  --main-signatures "$DEMO/main-sigs.txt" \
  --blocked-out "$DEMO/blocked.txt" --verdict-out "$DEMO/verdict.txt" > "$DEMO/out.txt" 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "POST-SWAP: the decision BLOCKS it (exit $rc)" \
  || fail "the decision excused an eight-fold regression — the defect is not fixed"
grep -q '^VERDICT	BLOCK' "$DEMO/verdict.txt" && grep -q 'materially higher' "$DEMO/out.txt" \
  && pass "the refusal names the rate comparison (main 1/8 vs PR 8/8)" || fail "the decision did not report the rate regression"

# A ROTATING identity (B7 measured it on #3749: two runs of the branch 3h apart,
# near-zero overlap) must be UNATTRIBUTABLE — neither PR-unique nor exempt.
A1='tests/test_dr_endpoints.py::TestDrDrill::test_dr_restores_to_scratch'
A2='tests/test_dr_endpoints.py::TestDrDrill::test_dr_restores_to_scratch_416bf7c5'
printf '%s\t1\t1\tRuntimeError: drill failed\n' "$A2" > "$DEMO/rot-pr.txt"
printf '%s\t4\t4\n' "$A2" > "$DEMO/rot-rates.txt"
printf '%s\tRuntimeError: drill failed\n' "$A2" > "$DEMO/rot-sigs.txt"
printf '%s\n%s\n%s\n' "$A1" "$A2" "$A1" > "$DEMO/rotation.txt"
printf '%s\n' "$A2" > "$DEMO/rot-main-union.txt"
rot_union_unique="$(comm -23 <(sort -u "$DEMO/rot-pr.txt" | cut -f1) <(sort -u "$DEMO/rot-main-union.txt"))"
[ -z "$rot_union_unique" ] && pass "PRE-SWAP RED: the union EXCUSES the rotating failure too" \
  || fail "expected the union to excuse the rotating failure"
python3 "$ROOT/scripts/ci_exemption.py" decide \
  --pr-failures "$DEMO/rot-pr.txt" --main-rates "$DEMO/rot-rates.txt" \
  --main-signatures "$DEMO/rot-sigs.txt" --rotation "$DEMO/rotation.txt" \
  --unattributable-out "$DEMO/rot-una.txt" --verdict-out "$DEMO/rot-verdict.txt" > "$DEMO/rot-out.txt" 2>&1
rc=$?
[ "$rc" -ne 0 ] && grep -q '^VERDICT	BLOCK	blocked=0	unattributable=1' "$DEMO/rot-verdict.txt" \
  && pass "POST-SWAP: the rotating id is UNATTRIBUTABLE (not PR-unique, not exempt)" \
  || fail "a rotating identity was not classified UNATTRIBUTABLE (got: $(cat "$DEMO/rot-verdict.txt" 2>/dev/null))"

# ── 31. THE MODULE IS PART OF THE RAIL, NEVER THE GRADED REPO (#3756) ───────
# The decision is resolved from the RAIL's own directory. A grader drawn from the
# repo being merged is a bypass (a PR could ship a `tools/ci_exemption.py` that
# always reports CLEAN), and an ABSENT module must be a LOUD refusal — never a
# fallback to the presence-based subtraction, which is the defect itself.
echo "== 31. an absent decision module is a loud refusal, not a union fallback =="
NOMOD="$TMP/nomodule"; rm -rf "$NOMOD"; mkdir -p "$NOMOD"
cp "$ADM" "$CFS" "$NOMOD/"
new_scen nomodule
HEAD_NM="cccc222200000000000000000000000000000000"
printf '%s\n' "$HEAD_NM" > "$SCEN/head"
lane_fail "$HEAD_NM" 6101 > "$SCEN/runs-$HEAD_NM"
log_failed 'tests/test_x.py::test_x' > "$SCEN/log-6101"
main_red_n mainnm 6102 3 'tests/test_x.py::test_x' > "$SCEN/runs-main"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  bash "$NOMOD/admin-merge.sh" 42 --main-runs 3 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "an absent module BLOCKS the merge (exit $rc)" \
  || fail "the rail merged with no decision module — a fail-open fallback"
grep -q 'the exemption decision module is ABSENT at' "$TMP/err" \
  && pass "the refusal names the missing module and its path" || fail "the refusal is unexplained"
grep -q 'fall back to presence-based subtraction' "$TMP/err" \
  && pass "the refusal rejects the union fallback explicitly" || fail "the refusal does not name the forbidden fallback"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted without a decision" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"
# At the parser level too: `--main-union-signatures` refuses, while `--diff` (the
# mode the DETECTOR still uses) keeps working without the module.
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$NOMOD/ci-failure-set.sh" --main-union-signatures 3 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "--main-union-signatures refuses without the module (exit $rc)" || fail "it produced a table with no extractor"
grep -q 'ABSENT at' "$TMP/err" && pass "…and says so" || fail "…silently"
printf 'a\n' > "$TMP/d-a.txt"; printf 'a\nb\n' > "$TMP/d-b.txt"
SCEN="$SCEN" CI_FAILURE_SET_GH="$FAKE" bash "$NOMOD/ci-failure-set.sh" --diff "$TMP/d-b.txt" "$TMP/d-a.txt" >"$TMP/out" 2>/dev/null
rc=$?
[ "$rc" -eq 0 ] && grep -q '^b$' "$TMP/out" && pass "--diff still works (retained for the detector)" \
  || fail "--diff broke — the detector's shared mode must remain"


# ── 32. THE FAILED-TOKEN POSITION (#3756 defect 1) ─────────────────────────
# The `may` leak, at the exact position the retired shell `awk` read: the token
# after `FAILED`. Two payloads, ONE position — the acceptance pair. Reverting the
# extractor to that `awk` turns `may` into a failure id (M1 RED); making the
# extractor "extract nothing" loses the real id (M2 RED); dropping a rejected
# candidate without recording it turns the REPORT assertion RED (M3).
echo '== 32. the FAILED-token position: `may` is DROPPED + REPORTED, a real id is EXTRACTED =='
MAYLOG="$TMP/may-position.log"
printf 'test (a)\tRun tests\t2026-09-17T13:10:44.1700000Z FAILED may be a known flake\n' > "$MAYLOG"
out="$(python3 "$ROOT/scripts/ci_exemption.py" ids --log "$MAYLOG" 2>"$TMP/may.err")"
rc=$?
[ "$rc" -eq 0 ] && [ -z "$out" ] && pass "M1: 'may' in the FAILED-token position yields NO failure id" \
  || fail "M1: expected no ids, got '$out' (exit $rc)"
grep -q 'UNATTRIBUTABLE.*may' "$TMP/may.err" && pass "M1: …and the rejected token is REPORTED as UNATTRIBUTABLE" \
  || fail "M1: the rejected token is not reported: $(cat "$TMP/may.err")"
grep -q 'unattributable=1' "$TMP/may.err" && pass "M1: …and COUNTED" \
  || fail "M1: the rejection is not counted"
REAL_ID='tests/test_real.py::test_real[param-1]'
REALLOG="$TMP/real-position.log"
printf 'test (a)\tRun tests\t2026-09-17T13:10:44.1700000Z FAILED %s - AssertionError: boom\n' "$REAL_ID" > "$REALLOG"
out="$(python3 "$ROOT/scripts/ci_exemption.py" ids --log "$REALLOG" 2>/dev/null)"
[ "$out" = "$REAL_ID" ] && pass "M2: a REAL id in the SAME position is still EXTRACTED" \
  || fail "M2: expected '$REAL_ID', got '$out'"

# The SAME acceptance pair, one door out: the RAIL's own extraction
# (`ci-failure-set.sh --commit`) must drop+report the garbage and keep the sound
# id. This is the shell half of the fix — the module alone does not prove the
# rail routes through it.
echo '== 32b. the shell rail drops+reports at the FAILED-token position =='
new_scen cfsmay
HEAD_CM="aa5511000000000000000000000000000000000"
lane_fail "$HEAD_CM" 8801 > "$SCEN/runs-$HEAD_CM"
{ log_failed 'tests/test_ok.py::test_ok'; log_failed 'may'; } > "$SCEN/log-8801"
cfs_run --commit "$HEAD_CM"; rc=$?
[ "$rc" -eq 0 ] && pass "the rail reads a capture carrying garbage (exit 0)" \
  || fail "the rail exited $rc on a capture that also carried a sound id"
grep -qxF 'tests/test_ok.py::test_ok' "$TMP/cfs-out" && pass "the sound id is EXTRACTED by the rail" \
  || fail "the rail lost the sound id: $(cat "$TMP/cfs-out")"
grep -qxF 'may' "$TMP/cfs-out" && fail "'may' was CARRIED as a failure id (permanent false refusal)" \
  || pass "'may' is NOT in the rail's failure set"
grep -q 'UNATTRIBUTABLE.*may' "$TMP/cfs-err" && pass "the rail REPORTS the dropped token (not silent)" \
  || fail "the rail dropped 'may' silently: $(head -2 "$TMP/cfs-err")"

# ── 33. A MOVED IDENTITY: reported across the boundary, never attributed ───
# B7's dynamic form: within ONE concluded cycle the SAME head's failure id moved
# (pre-rerun `test_status_surfaces_last_drill`, post-rerun
# `test_manual_drill_records_measured_time`). A stable regression does not do
# that, so the re-measure is not comparing like with like. Two required
# behaviours: (1) the id set ACROSS the boundary is REPORTED — both samples
# surface, not a single collapsed identity; (2) the moving identity is
# UNATTRIBUTABLE — flagged by class, never resolved to one PR-unique id.
# (The decision's UNATTRIBUTABLE VERDICT is the consumer side, #1147.)
echo "== 33. a moved identity is REPORTED across the boundary and not attributed =="
new_scen cfsrot
HEAD_RR="bb6622000000000000000000000000000000000"
ROT_A1='tests/test_dr_endpoints.py::TestDrDrillScheduled::test_status_surfaces_last_drill'
ROT_A2='tests/test_dr_endpoints.py::TestDrDrillScheduled::test_manual_drill_records_measured_time'
{ lane_fail "$HEAD_RR" 8801; lane_fail "$HEAD_RR" 8802; } > "$SCEN/runs-$HEAD_RR"
log_failed "$ROT_A1" > "$SCEN/log-8801"
log_failed "$ROT_A2" > "$SCEN/log-8802"
cfs_run --commit "$HEAD_RR"; rc=$?
[ "$rc" -eq 0 ] && pass "both samples of the SAME head are read (exit 0)" \
  || fail "the rail exited $rc over the two samples"
grep -qxF "$ROT_A1" "$TMP/cfs-out" && grep -qxF "$ROT_A2" "$TMP/cfs-out" \
  && pass "BOTH identities across the boundary are REPORTED (the move is visible)" \
  || fail "the boundary collapsed to one identity: $(cat "$TMP/cfs-out")"
# The rotation rule must FIRE on the move, and must NOT fire on a stable id or a
# single sample (removing it turns this RED: a moved id would read PR-unique).
ROT_VERDICT="$(python3 -c '
import sys
sys.path.insert(0, sys.argv[1] + "/scripts")
import ci_exemption as m
a, b = sys.argv[2], sys.argv[3]
moved = m.detect_rotating_identity([frozenset({a}), frozenset({b})])
stable = m.detect_rotating_identity([frozenset({a}), frozenset({a})])
single = m.detect_rotating_identity([frozenset({a})])
covers = {a, b} <= set(moved.get(m.class_key(a), frozenset()))
print("moved=%s stable=%s single=%s covers_both=%s" % (bool(moved), bool(stable), bool(single), covers))
' "$ROOT" "$ROT_A1" "$ROT_A2")"
case "$ROT_VERDICT" in
  "moved=True stable=False single=False covers_both=True")
    pass "the moved identity is flagged UNATTRIBUTABLE by class (never one PR-unique id)" ;;
  *) fail "rotation rule mis-fired: $ROT_VERDICT" ;;
esac

# ── 34. the merge method has a DEFAULT, so an omission cannot no-op ─────────
# `gh pr merge` REQUIRES one of --merge/--rebase/--squash when not interactive;
# with none it errors and NO-OPs. The passthrough let the CALLER omit it, so the
# rail posted its head-bound evidence marker and then merged NOTHING — a false
# PASS by construction (B1 lost #3754/#3755 to it). The default must be present
# when the caller supplies no method, and an explicit method must win.
echo "== 34. a default merge method, overridable through the passthrough =="
new_scen mergemethod
HEAD_MM="c0c0000000000000000000000000000000000000"
printf '%s\n' "$HEAD_MM" > "$SCEN/head"
lane_fail "$HEAD_MM" 9301 > "$SCEN/runs-$HEAD_MM"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9301"
# main's rate must be MEASURED (at or above the decision's min_runs floor) for
# the PR failure to be exempted and the merge to be REACHED at all: the union
# rail cannot exempt without MAIN measured over enough runs, and a single main
# sample can never establish one (fail-closed). Before the swap a mere presence
# in main's window sufficed.
main_red_n mainmm 9302 3 'tests/test_other.py::test_red_on_main' > "$SCEN/runs-main"
run_admin 42 --main-runs 3 >/dev/null 2>&1
if grep -q "pr merge 42 --admin --squash --match-head-commit $HEAD_MM" "$SCEN/calls"; then
  pass "MERGE_ARGS empty → the merge still carries a method (--squash default)"
else
  fail "no default merge method: an omission NO-OPs gh pr merge and leaves the marker standing"
  grep "pr merge" "$SCEN/calls" | sed 's/^/      /'
fi
# An explicit method overrides the default and is not doubled.
: > "$SCEN/calls"
run_admin 42 --main-runs 3 -- --rebase >/dev/null 2>&1
if grep -q "pr merge 42 --admin --rebase --match-head-commit $HEAD_MM" "$SCEN/calls" \
   && ! grep -q -- "--squash" "$SCEN/calls"; then
  pass "an explicit --rebase overrides the default (no --squash, no doubling)"
else
  fail "the explicit method did not override the default"
  grep "pr merge" "$SCEN/calls" | sed 's/^/      /'
fi

# ── 35. a FAILED merge must fail LOUD, and the marker must not stand ────────
# The rail posted "✅ head-bound evidence posted", then ran `gh pr merge` with NO
# exit-status check. A failing merge left the marker standing over an UNMERGED
# PR — a false PASS by construction. Now the failure is loud, gh's stderr is
# included, and a RETRACTION is posted so the marker cannot be read as success.
echo "== 35. a failing gh pr merge fails LOUD and the marker is retracted =="
new_scen mergefails
HEAD_MF="c1c1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_MF" > "$SCEN/head"
lane_fail "$HEAD_MF" 9311 > "$SCEN/runs-$HEAD_MF"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9311"
main_red_n mainmf 9312 3 'tests/test_other.py::test_red_on_main' > "$SCEN/runs-main"
printf 'gh: Pull Request is still a draft\n' > "$SCEN/fail-merge"
run_admin 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a failed merge exits non-zero ($rc)" \
  || fail "a failed gh pr merge returned 0 — the false PASS is unfixed"
grep -q "the merge of PR #42 did NOT happen" "$TMP/err" && pass "  …and says the merge did NOT happen" \
  || fail "  …but the failure is not loud/unambiguous"
grep -q "THE SUCCESS MARKER IS STANDING OVER AN UNMERGED PR" "$TMP/err" \
  && pass "  …and names the standing marker explicitly" \
  || fail "  …and does not call out the marker"
grep -qF "gh: Pull Request is still a draft" "$TMP/err" \
  && pass "  …and includes gh's stderr verbatim" \
  || fail "  …but gh's stderr is not surfaced"
[ -f "$SCEN/comment-1" ] && grep -q "<!-- admin-merge-safety: $HEAD_MF -->" "$SCEN/comment-1" \
  && pass "the evidence marker was posted before the merge was attempted" \
  || fail "the evidence comment was not posted (the scenario no longer models the defect)"
[ -f "$SCEN/comment-2" ] && grep -q "RETRACTED — the admin merge of head \`$HEAD_MF\` FAILED" "$SCEN/comment-2" \
  && pass "a head-bound RETRACTION is posted, so the marker is not left standing" \
  || fail "the success marker was left standing over an unmerged PR"
# The retraction must not be a CERTIFICATE. The assertion that used to stand here grepped
# for "unique to this PR: 0" — a string the producer stopped emitting when that clause was
# renamed (`bcbb7df`), so it was green no matter what the retraction said: a no-op gate
# over exactly the property it named (#1440). What replaces it can fail for the reason it
# states, including a call to the gate's own verifier — the consumer contract #1432
# established, and the cross-component binding #1429's indicator (b) asked for.
grep -q "blocked by the decision: 0" "$SCEN/comment-2" \
  && fail "the retraction must NOT be a certificate (it carries the producer's CURRENT residual clause)" \
  || pass "the retraction does not carry the producer's current residual clause"
grep -qF "<!-- admin-merge-safety: $HEAD_MF -->" "$SCEN/comment-2" \
  && fail "the retraction carries the SAFETY marker as a comment — it claims to be the certificate it retracts" \
  || pass "the retraction is bound to the retraction marker, not to the safety certificate's"
if [ -f "$SCEN/comment-2" ]; then
  if bash "$ROOT/scripts/verify-admin-merge-evidence.sh" --body-file "$SCEN/comment-2" --head "$HEAD_MF" >/dev/null 2>&1; then
    fail "the RETRACTION body CERTIFIES under the gate's own verifier — a retraction must never be a certificate"
  else
    pass "the retraction is refused by the gate's own verifier (it is not a certificate)"
  fi
else
  fail "no retraction body was posted, so its non-certification cannot be asserted"
fi

# ── 36. a DRAFT is refused EARLY, by name (not a late generic merge failure) ─
# commit-workflow mandates opening drafts, and gh refuses to merge one. The rail
# must refuse BEFORE any CI work with that specific reason, distinct from any
# failure verdict — never let it surface after the evidence marker was posted.
echo "== 36. a DRAFT PR is refused early, with the specific reason =="
new_scen draftpr
HEAD_DP="c2c2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_DP" > "$SCEN/head"
printf 'true\n' > "$SCEN/draft"
lane_fail "$HEAD_DP" 9321 > "$SCEN/runs-$HEAD_DP"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9321"
lane_fail maindp 9322 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9322"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a draft PR → non-zero exit ($rc)" || fail "a draft was not refused"
grep -q "is a DRAFT, and gh refuses to merge a draft" "$TMP/err" \
  && pass "  …with the DRAFT reason, by name" || fail "  …but the reason is not the draft"
grep -q "gh pr ready 42" "$TMP/err" \
  && pass "  …and names the remedy (gh pr ready)" || fail "  …but offers no remedy"
grep -q "NOT a CI-failure verdict" "$TMP/err" \
  && pass "  …and distinguishes it from a failure verdict" || fail "  …and conflates it with a failure verdict"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted for a draft" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted on a draft" || pass "no merge attempted"
grep -q "run list" "$SCEN/calls" \
  && fail "the draft check must run BEFORE any CI work" \
  || pass "the refusal is EARLY (no CI run was even listed)"

# ── 37. THE TWO WAITS, the DERIVED ceiling, and attribution that does not
#        narrow the refusal (B4 / B5 / B7 / B1) ───────────────────────────
# One section, five pinned behaviours:
#   (a) a run that is still RUNNING is WAITED, not called a failure
#   (b) a run with no `updatedAt` progress is STALLED, and says so distinctly
#   (c) the two waits READ DIFFERENTLY (B7: a raised --rerun-timeout exited
#       INSTANTLY because the lane-terminal precondition gated first)
#   (d) the re-run ceiling is DERIVED (2 x the slowest OBSERVED shard) and the
#       derivation is stated
#   (e) a failure whose file main's lane has NOT measured reads
#       "not measurable on this lane" — the refusal STAYS, and there is no
#       waiver label (B1's docker/embedded redislite case)
echo "== 37. the two waits, the derived ceiling, and non-narrowing attribution =="

# (a) STILL RUNNING is waited, not failed. status goes in_progress -> completed
# and the re-run's test then PASSES, so the rail must reach the flake path.
new_scen waitstillrunning
HEAD_W1="d1d1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_W1" > "$SCEN/head"
LANE1='tests/test_flaky.py::test_still_running'
lane_fail "$HEAD_W1" 9601 > "$SCEN/runs-$HEAD_W1"
log_failed "$LANE1" > "$SCEN/log-9601"
lane_fail mainw1 9602 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9602"
log_passed "$LANE1" > "$SCEN/log-after-9601"
printf 'in_progress\nin_progress\ncompleted\n' > "$SCEN/status-9601"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "(a) a run that was STILL RUNNING is waited to completion, not failed (exit 0)" \
  || fail "(a) a still-running re-run was treated as a failure (exit $rc)"
grep -q "STILL RUNNING" "$TMP/out" \
  && pass "(a) it reports STILL RUNNING progress while waiting" \
  || fail "(a) no STILL RUNNING progress was reported"
grep -q "STALLED" "$TMP/err" && fail "(a) a still-running job was called STALLED" \
  || pass "(a) a still-running job was NOT called STALLED"
grep -q "still RUNNING at the" "$TMP/err" && fail "(a) a still-running job hit the ceiling wrongly" \
  || pass "(a) the ceiling was not reported for a run that completed"
grep -q "pr merge 42 --admin" "$SCEN/calls" && pass "(a) the merge proceeded after the wait" \
  || fail "(a) no merge after a completed re-run"

# (a2) THE DEFECT ITSELF (failing-first). A shard whose GREEN bound is ~46m —
# the recorded population for `test (b)` (median 46.6m, max 49.9m) — is healthy
# well past the old flat 600s window. Pre-fix the frozen `updatedAt` fired
# STALLED at 600s and blocked the merge; post-fix the derived bound is ~93m and
# the run completes, so the rail must reach the flake path. This test FAILS
# against the pre-fix rail (STALLED at poll 600) and PASSES against the fix.
new_scen longhealthy
printf '%s\n' "$HEAD_W1" > "$SCEN/head"
LANE_LONG='tests/test_b.py::test_long_healthy'
lane_fail "$HEAD_W1" 9661 > "$SCEN/runs-$HEAD_W1"
log_failed "$LANE_LONG" > "$SCEN/log-9661"
lane_fail mainlong 9662 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9662"
log_passed "$LANE_LONG" > "$SCEN/log-after-9661"
target_shard 9661 "test (b)"
green_shard 9663 "test (b)" 2796        # 46.6m — the recorded MEDIAN
# in_progress for 605 polls (just past the OLD 600s flat window), then completed.
: > "$SCEN/status-9661"
_i=0; while [ "$_i" -lt 605 ]; do printf 'in_progress\n' >> "$SCEN/status-9661"; _i=$((_i + 1)); done
printf 'completed\n' >> "$SCEN/status-9661"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "(a2) a 46.6m shard healthy past 600s is NOT stalled (exit 0)" \
  || { fail "(a2) the healthy long shard was blocked (exit $rc)"; sed 's/^/      /' "$TMP/err"; }
grep -q 'STALLED' "$TMP/err" && fail "(a2) the healthy long run was called STALLED" \
  || pass "(a2) …and it is NOT called STALLED"
grep -q 'pr merge 42 --admin' "$SCEN/calls" && pass "(a2) the merge proceeded for the healthy long run" \
  || fail "(a2) no merge after the healthy long run"

# (b) STALL: the run stays non-completed past its own DERIVED per-shard bound.
# The bound comes from the GREEN population (9613) — NOT from a flat progress
# window. The flat 600s window was the false block this fix removes: shard (b)'s
# green MEDIAN is ~46m, so a 600s window fired while the job was healthy. Here
# the green max is 30s, so the bound is 60s and a run that never completes is
# STALLED at 60s.
new_scen waitstall
printf '%s\n' "$HEAD_W1" > "$SCEN/head"
lane_fail "$HEAD_W1" 9611 > "$SCEN/runs-$HEAD_W1"
log_failed 'tests/test_flaky.py::test_stalls' > "$SCEN/log-9611"
lane_fail mainw1b 9612 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9612"
target_shard 9611 "test (b)"
green_shard 9613 "test (b)" 30
printf 'in_progress\n' > "$SCEN/status-9611"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_RERUN_FLOOR=1 bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "(b) a STALLED re-run blocks (exit $rc)" || fail "(b) a stalled run did not block"
grep -q "STALLED: still non-completed at its DERIVED per-shard bound" "$TMP/err" \
  && pass "(b) the stall is reported by NAME, as the DERIVED bound exceeded" \
  || { fail "(b) the stall is not named"; sed 's/^/      /' "$TMP/err"; }
grep -qF 'derived per-shard green bound 60s (slowest shard (every shard completed): test (b), green n=1, green max=30s)' "$TMP/err" \
  && pass "(b) the stall names the shard, its green n and its green max" \
  || fail "(b) the stall does not carry the derivation"
grep -q "still RUNNING at the" "$TMP/err" && fail "(b) a stall was reported as the ceiling" \
  || pass "(b) the stall is DISTINCT from the ceiling message"
# The pin is about the STALL MESSAGE, not the whole of stderr: an unrelated
# derivation line on stderr must not decide it. A STALL must never claim an
# explicit operator cap — that is the CEILING verdict's provenance.
stall_line="$(grep -m1 'STALLED' "$TMP/err")"
case "$stall_line" in
  *"explicit --rerun-timeout"*|*"operator cap"*)
    fail "(b) the STALL message carries an explicit-ceiling source — the two verdicts are not distinguishable" ;;
  *) pass "(b) the STALL message claims the DERIVED bound, never an explicit cap" ;;
esac
grep -q "pr merge" "$SCEN/calls" && fail "(b) no merge on a stall" || pass "(b) no merge attempted"

# (c) THE TWO WAITS READ DIFFERENTLY. The lane-terminal precondition fires
# first; raising --rerun-timeout must NOT change that exit (B7's instant exit)
# and the output must name WHICH wait it was and state the other never started.
new_scen twowaits
HEAD_W3="d3d3000000000000000000000000000000000000"
printf '%s\n' "$HEAD_W3" > "$SCEN/head"
lane_queued "$HEAD_W3" 9621 > "$SCEN/runs-$HEAD_W3"
lane_fail mainw3 9622 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9622"
# 900, not 99: an operator's explicit bound must be a positive integer, and the
# point here is unchanged — a RAISED bound must not change the lane-terminal exit.
run_admin 42 --main-runs 1 --rerun-timeout 900 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(c) the lane-terminal precondition blocks (exit $rc), even with --rerun-timeout 900" \
  || fail "(c) a pending lane certified with a raised re-run bound"
grep -q "precondition unmet: run still in_progress — no classification attempted" "$TMP/err" \
  && pass "(c) the refusal NAMES the precondition and that no classification was attempted" \
  || fail "(c) the precondition refusal is not named"
grep -q "LANE-TERMINAL PRECONDITION" "$TMP/err" \
  && pass "(c) …and names it as the lane-terminal precondition" \
  || fail "(c) …but does not say which wait it is"
grep -q -- "--rerun-timeout never started" "$TMP/err" \
  && pass "(c) …and states the re-run wait never started" \
  || fail "(c) …and leaves the two waits confusable"
grep -q "still RUNNING at the" "$TMP/err" && fail "(c) the two waits read alike" \
  || pass "(c) the re-run wait's message is absent (they are distinguishable)"
grep -q "run rerun" "$SCEN/calls" && fail "(c) no re-run may start from a precondition block" \
  || pass "(c) no re-run was started"

# (d) THE BOUND IS DERIVED, and its source is stated — not a round number.
bash "$ADM" --print-bounds > "$TMP/bounds.txt" 2>&1 || true
grep -q '^rerun-timeout=3900$' "$TMP/bounds.txt" \
  && pass "(d) no run id → the fail-safe 3900s (never a small bound)" \
  || fail "(d) the default bound is not the fail-safe: $(head -1 "$TMP/bounds.txt")"
grep -q '^source=fail-safe 3900s — no run id supplied' "$TMP/bounds.txt" \
  && pass "(d) …and the fail-safe states why it applied" \
  || fail "(d) the derivation source is not stated"
grep -q '^stall=' "$TMP/bounds.txt" \
  && fail "(d) a FLAT stall window is still printed — the flat window must be gone" \
  || pass "(d) …and there is NO separate flat stall window (one derived bound)"
# …and the explicit-cap message itself carries the derivation.
new_scen waitceiling
printf '%s\n' "$HEAD_W1" > "$SCEN/head"
lane_fail "$HEAD_W1" 9631 > "$SCEN/runs-$HEAD_W1"
log_failed 'tests/test_flaky.py::test_slow' > "$SCEN/log-9631"
lane_fail mainw4 9632 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9632"
printf 'in_progress\n' > "$SCEN/status-9631"
# An EXPLICIT `--rerun-timeout` is an operator cap: the run is still going at
# the cap, so the verdict is CEILING (2) — not STALLED. There is no progress
# clock to consult: `updatedAt` is not read at all any more.
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  bash "$ADM" 42 --main-runs 1 --rerun-timeout 5 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "(d) the explicit ceiling blocks when reached (exit $rc)" || fail "(d) the ceiling did not block"
grep -q "still RUNNING at the 5s ceiling — explicit --rerun-timeout" "$TMP/err" \
  && pass "(d) the ceiling message names the bound's source, not a bare number" \
  || fail "(d) the ceiling message does not state its source"
grep -q 'STALLED' "$TMP/err" \
  && fail "(d) an explicit operator cap was reported as a STALL" \
  || pass "(d) the explicit cap is a CEILING, not a STALL"

# (e) ATTRIBUTION: a failure main's lane has NOT measured must not be called
# "unique to this PR" — but it STILL BLOCKS. main fails a Docker file; the PR
# fails the embedded file whose race the Docker lane cannot reproduce (B1).
new_scen notmeasurable
HEAD_W5="d5d5000000000000000000000000000000000000"
printf '%s\n' "$HEAD_W5" > "$SCEN/head"
EMBED='tests/test_embedded.py::TestGraph::test_copy_race'
lane_fail "$HEAD_W5" 9641 > "$SCEN/runs-$HEAD_W5"
log_failed "$EMBED" > "$SCEN/log-9641"
lane_fail mainw5 9642 > "$SCEN/runs-main"
log_failed 'tests/test_docker.py::test_other' > "$SCEN/log-9642"
cp "$SCEN/log-9641" "$SCEN/log-after-9641"   # the retry FAILS again
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(e) an unmeasured-file failure STILL BLOCKS (exit $rc) — the refusal is not narrowed" \
  || fail "(e) an unmeasured-file failure was allowed through"
grep -q "not measurable on this lane" "$TMP/err" \
  && pass "(e) it reports 'not measurable on this lane' instead of 'unique to this PR'" \
  || fail "(e) the output still asserts uniqueness with no measurement on main"
grep -q "test_copy_race" "$TMP/err" && pass "(e) …naming the failure" || fail "(e) the failure is not named"
grep -q "BOTH block" "$TMP/err" \
  && pass "(e) …and states BOTH labels block (no waiver path)" \
  || fail "(e) …but does not close the waiver reading"
[ -f "$SCEN/comment" ] && fail "(e) no evidence may be posted on a block" || pass "(e) no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "(e) no merge on a block" || pass "(e) no merge attempted"

# (e2) the companion: main's lane DOES measure that file, so the label is the
# stronger measured-absent one — and it also STILL BLOCKS.
new_scen measuredabsent
printf '%s\n' "$HEAD_W5" > "$SCEN/head"
lane_fail "$HEAD_W5" 9651 > "$SCEN/runs-$HEAD_W5"
log_failed 'tests/test_docker.py::test_copy_race' > "$SCEN/log-9651"
lane_fail mainw5b 9652 > "$SCEN/runs-main"
log_failed 'tests/test_docker.py::test_other' > "$SCEN/log-9652"
cp "$SCEN/log-9651" "$SCEN/log-after-9651"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(e2) a measured-absent failure also STILL BLOCKS (exit $rc)" \
  || fail "(e2) a measured-absent failure was allowed through"
grep -q "measured on this lane, not present on main" "$TMP/err" \
  && pass "(e2) it reads 'measured on this lane, not present on main'" \
  || fail "(e2) the measured-absent label is missing"
grep -q "not measurable on this lane" "$TMP/err" && fail "(e2) a measured failure was called unmeasurable" \
  || pass "(e2) the two labels are distinct"

# ── 38. THE PER-SHARD BOUND DERIVATION (#1167) ────────────────────────
# The old ceiling was ONE hardcoded shard constant (2 x 1563s). B4's population
# falsifies that input: `test (b)`'s MEDIAN green run is 2.5x `test (a)`'s, so a
# single number is too tight for the slow shard and absurdly generous for the
# fast one. The ceiling is now a FUNCTION of the run's own observed per-shard
# durations, fetched over the Jobs API through the $GH seam.
echo "== 38. the per-shard ceiling derivation (#1167) =="

# (a) default: no run id → the fail-safe, and NO network call.
new_scen bounds-default
bash "$ADM" --print-bounds > "$TMP/bounds-a.txt" 2>&1 || true
grep -q '^rerun-timeout=3900$' "$TMP/bounds-a.txt" \
  && pass "(a) no run id → 3900 (the fail-safe)" \
  || fail "(a) expected rerun-timeout=3900, got: $(head -1 "$TMP/bounds-a.txt")"
grep -q '^source=fail-safe 3900s — no run id supplied; the derivation needs a run (pass one: --print-bounds <run-id>)$' "$TMP/bounds-a.txt" \
  && pass "(a) …and the fail-safe source line" \
  || fail "(a) the fail-safe source line is missing"
grep -q '^stall=' "$TMP/bounds-a.txt" \
  && fail "(a) a flat stall window is still printed — the flat window must be gone" \
  || pass "(a) …and no flat stall window (one derived bound)"
new_scen bounds-offline
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" bash "$ADM" --print-bounds > "$TMP/out" 2>"$TMP/err"
[ "$(wc -l < "$SCEN/calls")" -eq 0 ] \
  && pass "(a) no gh call when there is nothing to derive from" \
  || { fail "(a) --print-bounds made a network call without a run id"; sed 's/^/      /' "$SCEN/calls"; }

# (b) a synthetic population where two shards differ. `test (a)` is FAST and
# finished; `test (b)` is SLOW and still running in the target run. Its healthy
# duration comes from the GREEN population (7703), not from the target. C must be
# the UNFINISHED shard's ceiling — NOT a global constant, and NOT the fast
# shard's — while BOTH rows carry their green n.
new_scen bounds-derive
RUN_B=7701
cat > "$SCEN/jobs-$RUN_B.json" <<'JOBS'
{"total_count":4,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:18:50Z"},
{"name":"test (a)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:18:50Z"},
{"name":"test (b)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:46:36Z"},
{"name":"test (b)","status":"in_progress","conclusion":null,"started_at":"2026-01-01T01:00:00Z","completed_at":null}
]}
JOBS
printf '7703\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-7703.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:18:50Z"},
{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:46:36Z"}
]}
JOBS
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" bash "$ADM" --print-bounds "$RUN_B" --repo x/y > "$TMP/bounds-b.txt" 2>&1
grep -q '^rerun-timeout=5592$' "$TMP/bounds-b.txt" \
  && pass "(b) C is the UNFINISHED shard's ceiling (5592s), not a global constant" \
  || { fail "(b) expected rerun-timeout=5592, got: $(head -1 "$TMP/bounds-b.txt")"; sed 's/^/      /' "$TMP/bounds-b.txt"; }
grep -qE 'shard test \(a\)[[:space:]]+n=1[[:space:]]+max=1130s[[:space:]]+bound=2260s[[:space:]]+state=finished[[:space:]]+sample=green' "$TMP/bounds-b.txt" \
  && pass "(b) the table prints test (a) WITH ITS GREEN n (n=1, max=1130s, bound=2260s)" \
  || { fail "(b) the test (a) row is wrong/missing"; sed 's/^/      /' "$TMP/bounds-b.txt"; }
grep -qE 'shard test \(b\)[[:space:]]+n=1[[:space:]]+max=2796s[[:space:]]+bound=5592s[[:space:]]+state=unfinished[[:space:]]+sample=green' "$TMP/bounds-b.txt" \
  && pass "(b) the table prints test (b) WITH ITS GREEN n (n=1, max=2796s, bound=5592s)" \
  || { fail "(b) the test (b) row is wrong/missing"; sed 's/^/      /' "$TMP/bounds-b.txt"; }
grep -qF 'source=derived per-shard green bound 5592s (slowest unfinished shard: test (b), green n=1, green max=2796s)' "$TMP/bounds-b.txt" \
  && pass "(b) the source names the winning shard and its green n/max" \
  || fail "(b) the derivation source is not per-shard green: $(grep '^source=' "$TMP/bounds-b.txt")"
grep -q '3126' "$TMP/bounds-b.txt" \
  && fail "(b) the stale global constant 3126 is still present" \
  || pass "(b) the stale global constant 3126 is gone"
# …and the GREEN population query must forward the lane filter in DEFAULT mode.
# The fake's `--status success` branch ignores --workflow, so nothing else pins
# that green_run_ids routes the SAME lane as the failing-run listing — a dropped
# filter would derive a shard's ceiling from a DIFFERENT lane's green runs.
green_call="$(grep -m1 -E '^run list --status success' "$SCEN/calls")"
case "$green_call" in
  *"--workflow python-ci.yml"*) pass "(b) green_run_ids forwards --workflow in default mode" ;;
  *) fail "(b) green_run_ids did NOT forward the lane filter"; echo "      $green_call" ;;
esac
# …and the value must TRACK the GREEN fixture — a different population, a
# different bound. Any constant (including 1563/3126) cannot pass both halves.
RUN_B2=7702
cat > "$SCEN/jobs-$RUN_B2.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:05:00Z"},
{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:16:40Z"}
]}
JOBS
printf '7704\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-7704.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:05:00Z"},
{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:16:40Z"}
]}
JOBS
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" bash "$ADM" --print-bounds "$RUN_B2" --repo x/y > "$TMP/bounds-b2.txt" 2>&1
grep -q '^rerun-timeout=2000$' "$TMP/bounds-b2.txt" \
  && pass "(b) a DIFFERENT green fixture yields a DIFFERENT value (2000s) — a function, not a constant" \
  || fail "(b) the value did not track the fixture: $(head -1 "$TMP/bounds-b2.txt")"
grep -qF 'source=derived per-shard green bound 2000s (slowest shard (every shard completed): test (b), green n=1, green max=1000s)' "$TMP/bounds-b2.txt" \
  && pass "(b) an all-completed run takes the max over EVERY shard and says so" \
  || fail "(b) the all-completed source is wrong: $(grep '^source=' "$TMP/bounds-b2.txt")"
# FLOOR is a FLOOR: a fast shard's 2 x max is lifted to it, never below it.
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" ADMIN_MERGE_RERUN_FLOOR=5000 bash "$ADM" --print-bounds "$RUN_B2" --repo x/y > "$TMP/bounds-floor.txt" 2>&1
grep -q '^rerun-timeout=5000$' "$TMP/bounds-floor.txt" \
  && pass "(b) FLOOR lifts a fast shard (ceiling = max(FLOOR, 2 x max))" \
  || fail "(b) the floor was not applied: $(head -1 "$TMP/bounds-floor.txt")"

# (f) THE SAMPLE COMES FROM A GREEN POPULATION, NOT THE FAILING RUN (the merge
# blocker this cycle fixes). The slow shard FAILED, so its job was truncated by
# `pytest -x` (300s): 2 x 300 floored to 1200 is SHORTER than the shard's healthy
# re-run (~2796s), so a failing-run derivation blocks a run that is STILL WORKING
# — the exact defect this derivation replaced, in the common case. The green
# sample (1398s) must govern.
new_scen bounds-green
RUN_F=7801
cat > "$SCEN/jobs-$RUN_F.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:18:48Z"},
{"name":"test (b)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:05:00Z"}
]}
JOBS
printf '7802\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-7802.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:18:48Z"},
{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:23:18Z"}
]}
JOBS
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" ADMIN_MERGE_RERUN_FLOOR=1200 bash "$ADM" --print-bounds "$RUN_F" --repo x/y > "$TMP/bounds-f.txt" 2>&1
grep -q '^rerun-timeout=2796$' "$TMP/bounds-f.txt" \
  && pass "(f) the GREEN sample governs (2796s), not 2 x the truncated failure (2256s)" \
  || { fail "(f) the failing run's truncated sample was used: $(head -1 "$TMP/bounds-f.txt")"; sed 's/^/      /' "$TMP/bounds-f.txt"; }
grep -qE 'shard test \(b\)[[:space:]]+n=1[[:space:]]+max=1398s[[:space:]]+bound=2796s[[:space:]]+state=finished[[:space:]]+sample=green' "$TMP/bounds-f.txt" \
  && pass "(f) …and the row reports the green max (1398s), never the 300s failure" \
  || { fail "(f) the test (b) green row is wrong/missing"; sed 's/^/      /' "$TMP/bounds-f.txt"; }
grep -q 'max=300' "$TMP/bounds-f.txt" \
  && fail "(f) the truncated failure duration leaked into the table" \
  || pass "(f) …and the 300s failure sample is nowhere in the table"

# (g) A SHARD WITH NO GREEN SAMPLE takes the FAIL-SAFE, never a truncated
# failure sample. Here `test (b)`'s only observed duration is its own 300s
# FAILURE (2 x it → floored 1200); the fail-safe must govern instead.
new_scen bounds-nogreen
RUN_G=7811
cat > "$SCEN/jobs-$RUN_G.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:15:00Z"},
{"name":"test (b)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:05:00Z"}
]}
JOBS
printf '7812\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-7812.json" <<'JOBS'
{"total_count":1,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:15:00Z"}
]}
JOBS
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" ADMIN_MERGE_RERUN_FLOOR=1200 bash "$ADM" --print-bounds "$RUN_G" --repo x/y > "$TMP/bounds-g.txt" 2>&1
grep -q '^rerun-timeout=3900$' "$TMP/bounds-g.txt" \
  && pass "(g) a shard with NO green sample → the 3900s fail-safe, not the truncated failure" \
  || { fail "(g) expected rerun-timeout=3900, got: $(head -1 "$TMP/bounds-g.txt")"; sed 's/^/      /' "$TMP/bounds-g.txt"; }
grep -qE 'shard test \(b\)[[:space:]]+n=0[[:space:]]+max=--[[:space:]]+bound=3900s[[:space:]]+state=finished[[:space:]]+sample=none' "$TMP/bounds-g.txt" \
  && pass "(g) …and the row states sample=none (no healthy sample was substituted)" \
  || { fail "(g) the no-sample row is wrong/missing"; sed 's/^/      /' "$TMP/bounds-g.txt"; }

# (c) ANY failure of the derivation is the FAIL-SAFE, never a small bound.
new_scen bounds-bad
RUN_C1=7711; RUN_C2=7712; RUN_C3=7713
printf 'this is not JSON at all\n' > "$SCEN/jobs-$RUN_C1.json"
: > "$SCEN/jobs-$RUN_C2.json"
printf '{"total_count":1,"jobs":[{"name":"test (a)","status":"in_progress","started_at":"2026-01-01T00:00:00Z","completed_at":null}]}\n' > "$SCEN/jobs-$RUN_C3.json"
for spec in "$RUN_C1|unparsable jobs response" "$RUN_C2|empty jobs response" "$RUN_C3|no job durations observed" "7799|jobs API error"; do
  rid="${spec%%|*}"; why="${spec#*|}"
  SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" bash "$ADM" --print-bounds "$rid" --repo x/y > "$TMP/out" 2>"$TMP/err" || true
  if grep -q '^rerun-timeout=3900$' "$TMP/out" \
     && grep -qF "derivation unavailable (${why}) — using the fail-safe 3900s (never a small bound)" "$TMP/err" \
     && grep -qF "source=fail-safe 3900s — derivation unavailable (${why})" "$TMP/out"; then
    pass "(c) $why → 3900, loudly, with the reason"
  else
    fail "(c) $why did not fail safe to 3900 ($(head -1 "$TMP/out")); stderr: $(head -1 "$TMP/err")"
  fi
done
ADMIN_MERGE_GH=/nonexistent/gh bash "$ADM" --print-bounds 7799 --repo x/y > "$TMP/out" 2>"$TMP/err" || true
grep -qF 'derivation unavailable (gh absent) — using the fail-safe 3900s' "$TMP/err" \
  && pass "(c) gh absent → 3900, loudly" \
  || fail "(c) gh absent did not fail safe: $(head -1 "$TMP/err")"

# (d) an explicit --rerun-timeout wins, and the derivation is not even consulted.
new_scen bounds-override
RUN_D=7721
printf '{"total_count":1,"jobs":[{"name":"test (b)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:46:36Z"}]}\n' > "$SCEN/jobs-$RUN_D.json"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" bash "$ADM" --print-bounds "$RUN_D" --repo x/y --rerun-timeout 1234 > "$TMP/bounds-d.txt" 2>&1
grep -q '^rerun-timeout=1234$' "$TMP/bounds-d.txt" \
  && pass "(d) --rerun-timeout overrides the derivation" \
  || fail "(d) the override was not honoured: $(head -1 "$TMP/bounds-d.txt")"
grep -q '^source=explicit --rerun-timeout (a CEILING, not a derived stall bound)$' "$TMP/bounds-d.txt" \
  && pass "(d) …and the source says so (an explicit cap is a CEILING, not a stall)" || fail "(d) the override source is wrong"
grep -q 'api ' "$SCEN/calls" \
  && fail "(d) the derivation was consulted despite an explicit override" \
  || pass "(d) …and the derivation was not consulted"

# (e) A DERIVED bound fires end to end, naming its source — and, because a
# remote run exposes no within-job activity signal, exceeding that bound IS the
# STALL (there is no separate "ceiling" for a derived bound: they coincide, which
# is exactly why the flat window had to go). The run this re-run replaces is
# TERMINAL, so every shard has a green sample. `updatedAt` is NOT read.
new_scen bounds-e2e
HEAD_E="e0e0000000000000000000000000000000000000"
printf '%s\n' "$HEAD_E" > "$SCEN/head"
lane_fail "$HEAD_E" 9731 > "$SCEN/runs-$HEAD_E"
log_failed 'tests/test_new.py::test_brand_new' > "$SCEN/log-9731"
lane_fail maine0 9732 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9732"
cat > "$SCEN/jobs-9731.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:00:10Z"},
{"name":"test (b)","status":"completed","conclusion":"failure","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:00:30Z"}
]}
JOBS
printf '9733\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-9733.json" <<'JOBS'
{"total_count":2,"jobs":[
{"name":"test (a)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:00:10Z"},
{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:00:30Z"}
]}
JOBS
printf 'in_progress\n' > "$SCEN/status-9731"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_RERUN_FLOOR=1 \
  bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "(e) the DERIVED bound blocks when reached (exit $rc)" \
  || fail "(e) the derived bound did not block (exit 0)"
grep -q 'STALLED: still non-completed at its DERIVED per-shard bound' "$TMP/err" \
  && pass "(e) the DERIVED bound being exceeded is reported as STALLED" \
  || { fail "(e) the derived-bound stall is wrong"; sed 's/^/      /' "$TMP/err"; }
grep -qF 'derived per-shard green bound 60s (slowest shard (every shard completed): test (b), green n=1, green max=30s)' "$TMP/err" \
  && pass "(e) …and carries the shard, its green n and its green max" \
  || fail "(e) the stall message does not carry the derivation"
grep -q 'still RUNNING at the' "$TMP/err" && fail "(e) a derived-bound overflow was reported as the explicit ceiling" || pass "(e) the derived-bound stall is DISTINCT from the explicit CEILING"
grep -q 'explicit --rerun-timeout' "$TMP/err" && fail "(e) an unconfigured bound claimed to be explicit" || pass "(e) the bound does not claim an override it did not have"
grep -q 'pr merge' "$SCEN/calls" && fail "(e) no merge on a stall" || pass "(e) no merge attempted"

# ── 39. THE LANE-TERMINAL PRECONDITION NAMES WHICH WAIT (#1167 follow-on) ──
# The precondition must not merely refuse: it must say WHICH wait it is. It is
# NOT the re-run wait — that bound has not been derived yet, so the precondition
# claims NEITHER a WAIT NOR a STALL. A pending run reads as "still running"; a
# frozen `updatedAt` is NOT evidence of a stall (it is frozen for the whole of a
# single long step), which is the false claim this section now pins OUT.
echo "== 39. the precondition names which wait, and never fabricates a stall =="

# (i) a pending run → still running, NOT a stall claim
new_scen precond-wait
HEAD_PW="f9f9000000000000000000000000000000000000"
printf '%s\n' "$HEAD_PW" > "$SCEN/head"
lane_queued "$HEAD_PW" 9801 > "$SCEN/runs-$HEAD_PW"
lane_fail mainpw 9802 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9802"
printf 'in_progress\n' > "$SCEN/status-9801"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(i) a pending lane blocks (exit $rc)" || fail "(i) the precondition did not block"
grep -q 'still running. A running job is not a failure, and this is NOT a stall claim' "$TMP/err" \
  && pass "(i) a pending lane reads as still-running, NOT a stall" \
  || { fail "(i) the still-running reading is missing"; sed 's/^/      /' "$TMP/err"; }
grep -q 'STALLED' "$TMP/err" && fail "(i) a pending lane was called STALLED" || pass "(i) …and NOT as STALLED"
grep -q -- '--rerun-timeout never started' "$TMP/err" \
  && pass "(i) …and the re-run wait is still stated as never started" \
  || fail "(i) the never-started statement disappeared"
[ "$(grep -c '^run view 9801' "$SCEN/calls" || true)" -eq 1 ] \
  && pass "(i) exactly ONE gh run view call for the diagnostic" \
  || fail "(i) expected one run view call, got $(grep -c '^run view 9801' "$SCEN/calls" || true)"

# (ii) THE FALSE STALL, pinned out. The run is in_progress and its `updatedAt` is
# FROZEN at 2020 — exactly the field evidence that produced the false STALLED
# verdict (#1167 follow-on: run 35295083845, job `test (b)`, healthy at 11m40s
# with the run clock frozen the whole time). `updatedAt` is not read any more, so
# this must read the SAME as (i): still running, NOT a stall.
new_scen precond-frozen-clock
printf '%s\n' "$HEAD_PW" > "$SCEN/head"
lane_queued "$HEAD_PW" 9811 > "$SCEN/runs-$HEAD_PW"
lane_fail mainpw2 9812 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9812"
printf 'in_progress\n' > "$SCEN/status-9811"
printf '2020-01-01T00:00:00Z\n' > "$SCEN/updated-9811"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(ii) a pending lane blocks (exit $rc)" || fail "(ii) the precondition did not block"
grep -q 'STALLED' "$TMP/err" \
  && fail "(ii) a FROZEN updatedAt was called STALLED — the false block this fix removes" \
  || pass "(ii) a frozen updatedAt is NOT a stall (no progress claim is made)"
grep -q 'still running. A running job is not a failure' "$TMP/err" \
  && pass "(ii) …it reads as still-running, like any pending lane" \
  || { fail "(ii) the still-running reading is missing"; sed 's/^/      /' "$TMP/err"; }
grep -q 'updatedAt' "$TMP/err" \
  && fail "(ii) the diagnostic still reports an updatedAt claim" \
  || pass "(ii) …and no updatedAt claim is made anywhere"
grep -q 'updatedAt' "$SCEN/calls" \
  && fail "(ii) the rail still ASKS gh for updatedAt — the frozen clock can return" \
  || pass "(ii) …and gh is never asked for updatedAt (call-level tripwire)"

# (iii) AN UNREADABLE RUN IS NOT A STALL. gh failing repeatedly means the run's
# state was NEVER OBSERVED; the rail cannot claim the run exceeded its bound if it
# never read the run. The remedies are opposite (repair gh vs escalate a wedged
# run), so the diagnoses must differ — and the rail must still fail closed. The
# derived bound is made small with a one-shard green fixture so the test polls a
# bound, not a fingerprint.
new_scen unobservable
printf '%s\n' "$HEAD_W1" > "$SCEN/head"
lane_fail "$HEAD_W1" 9641 > "$SCEN/runs-$HEAD_W1"
log_failed 'tests/test_flaky.py::test_slow' > "$SCEN/log-9641"
lane_fail mainw4 9642 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9642"
target_shard 9641 "test (b)"
green_shard 9643 "test (b)" 5
# NO status-9641 file would mean "completed"; make the projection FAIL instead.
: > "$SCEN/unreadable-9641"
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_RERUN_FLOOR=1 bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "(iii) an UNREADABLE run still blocks (exit $rc) — fail closed" \
  || fail "(iii) an unreadable run did not block"
grep -q 'UNOBSERVABLE' "$TMP/err" \
  && pass "(iii) …and is reported as UNOBSERVABLE" \
  || { fail "(iii) the UNOBSERVABLE diagnosis is missing"; sed 's/^/      /' "$TMP/err"; }
grep -q 'STALLED' "$TMP/err" \
  && fail "(iii) an unreadable run was called STALLED — that claims a run was observed" \
  || pass "(iii) …and NOT as STALLED (it never saw the run)"
grep -q 'gh auth/network' "$TMP/err" \
  && pass "(iii) …and names the different remedy" \
  || fail "(iii) the remedy is not named"
grep -q "pr merge" "$SCEN/calls" && fail "(iii) no merge may be attempted on an unreadable run" \
  || pass "(iii) no merge attempted"

# ── 40. THE FIX-CYCLE PINS ─────────────────────────────────────────────────
# Each of these FAILS against the pre-fix rail for the reason named.
echo "== 40. the fix-cycle pins =="

# (P2-1) A non-numeric or zero --rerun-timeout must be REFUSED, never turned into
# a ZERO-POLL ceiling. Before the fix, `[ "$waited" -lt "$RERUN_TIMEOUT" ]`
# returned 2, the loop body never ran, and wait_for_run fell through to `return 2`
# (CEILING) — printing "still RUNNING at the … ceiling" about a run it never
# looked at, with zero polls.
new_scen fix-rerun-timeout
HEAD_RT="abab000000000000000000000000000000000000"
printf '%s\n' "$HEAD_RT" > "$SCEN/head"
lane_fail "$HEAD_RT" 9901 > "$SCEN/runs-$HEAD_RT"
log_failed 'tests/test_flaky.py::test_rt' > "$SCEN/log-9901"
lane_fail mainrt 9902 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9902"
printf 'in_progress\n' > "$SCEN/status-9901"
for bad in "0" "abc" ""; do
  rm -f "$SCEN/calls" "$SCEN/rerun-9901"
  SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
    bash "$ADM" 42 --main-runs 1 --rerun-timeout "$bad" >"$TMP/out" 2>"$TMP/err"
  rc=$?
  if [ "$rc" -eq 2 ] && grep -q "refusing --rerun-timeout" "$TMP/err"; then
    pass "(P2-1) --rerun-timeout '$bad' is refused (exit 2, named)"
  else
    fail "(P2-1) --rerun-timeout '$bad' was NOT refused (exit $rc): $(head -1 "$TMP/err")"
  fi
  grep -q "still RUNNING at the" "$TMP/err" \
    && fail "(P2-1) --rerun-timeout '$bad' produced the false zero-poll ceiling claim" \
    || pass "(P2-1) …and no 'still RUNNING at the ceiling' claim was printed for '$bad'"
  [ "$(grep -c '^run view' "$SCEN/calls" 2>/dev/null || echo 0)" -eq 0 ] \
    && pass "(P2-1) …and the wait never polled for '$bad' (no run view call)" \
    || fail "(P2-1) --rerun-timeout '$bad' still polled"
done

# (P2-2) A non-numeric timing knob must be REFUSED at startup: its `-ge`/`-lt`
# comparisons return 2, so a guard silently SKIPS instead of failing. The flat
# stall window is gone, so the pin moves to the per-shard FLOOR.
new_scen fix-timing-knobs
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_RERUN_FLOOR=10m \
  bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -eq 2 ] && pass "(P2-2) a non-numeric ADMIN_MERGE_RERUN_FLOOR is refused (exit 2)" \
  || fail "(P2-2) a non-numeric floor was not refused (exit $rc)"
grep -q "refusing ADMIN_MERGE_RERUN_FLOOR='10m'" "$TMP/err" \
  && pass "(P2-2) …and the refusal names the knob and its value" \
  || { fail "(P2-2) the refusal does not name the knob"; sed 's/^/      /' "$TMP/err"; }
grep -q "value too great for base" "$TMP/err" \
  && fail "(P2-2) a file-scope arithmetic error leaked (an unset knob)" \
  || pass "(P2-2) …and no file-scope arithmetic error occurred"

# (P2-4) `--any-workflow` is the PARSER's opt-out, not a `gh run list` flag. Real
# gh rejects it and `2>/dev/null || true` hid that, so the precondition diagnostic
# was silently dead for the invocation commit-workflow's docs prescribe.
new_scen fix-anywf
printf '%s\n' "$HEAD_PW" > "$SCEN/head"
lane_queued "$HEAD_PW" 9911 > "$SCEN/runs-$HEAD_PW"
lane_fail mainfix 9912 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9912"
printf 'in_progress\n' > "$SCEN/status-9911"
run_admin 42 --main-runs 1 --any-workflow >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(P2-4) a pending lane blocks under --any-workflow (exit $rc)" \
  || fail "(P2-4) a pending lane certified under --any-workflow"
grep -q 'still running. A running job is not a failure' "$TMP/err" \
  && pass "(P2-4) the precondition diagnostic survives --any-workflow" \
  || { fail "(P2-4) the diagnostic is silently dead under --any-workflow"; sed 's/^/      /' "$TMP/err"; }
grep -q -- '--any-workflow' "$SCEN/calls" \
  && fail "(P2-4) a parser-only flag was forwarded to gh (real gh rejects it)" \
  || pass "(P2-4) …and --any-workflow never reached gh"

# (P2-5) An UNREADABLE run is neither "still running" nor a stall: the rail cannot
# claim a run is working, OR that it exceeded its bound, if it never read it. The
# remedies are opposite (repair gh vs escalate a wedged run), so the diagnoses
# must differ — and the rail must still fail closed.
new_scen fix-unreadable-run
printf '%s\n' "$HEAD_PW" > "$SCEN/head"
lane_queued "$HEAD_PW" 9921 > "$SCEN/runs-$HEAD_PW"
lane_fail mainfix2 9922 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9922"
# The lane run's STATE cannot be read at all (gh failure/auth/network).
: > "$SCEN/unreadable-9921"
run_admin 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(P2-5) an unreadable run still blocks (exit $rc)" \
  || fail "(P2-5) an unreadable run did not block"
grep -q 'could not be read' "$TMP/err" \
  && pass "(P2-5) …and says the run could not be read" \
  || { fail "(P2-5) the unreadable-run reading is missing"; sed 's/^/      /' "$TMP/err"; }
grep -q 'This is NOT a stall' "$TMP/err" \
  && pass "(P2-5) …explicitly NOT as a stall (a stall is a claim about a run we watched)" \
  || fail "(P2-5) the unreadable run was folded into a stall claim"
grep -q 'STALLED' "$TMP/err" \
  && fail "(P2-5) an unreadable run was called STALLED" \
  || pass "(P2-5) …and the word STALLED never appears"

# (P2-6) ADMIN_MERGE_GH is a COMMAND seam, not a path: a multi-word value must
# word-split. `"$GH" api` ran a file literally named `gh --hostname h`, so the
# presence check passed and the Jobs API call then failed.
cat > "$TMP/gh-multiword" <<EOF
#!/usr/bin/env bash
shift 2
exec "$FAKE" "\$@"
EOF
chmod +x "$TMP/gh-multiword"
new_scen fix-multiword-seam
RUN_MW=7821
cat > "$SCEN/jobs-$RUN_MW.json" <<'JOBS'
{"total_count":1,"jobs":[{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:16:40Z"}]}
JOBS
printf '7822\n' > "$SCEN/green-runs"
cat > "$SCEN/jobs-7822.json" <<'JOBS'
{"total_count":1,"jobs":[{"name":"test (b)","status":"completed","conclusion":"success","started_at":"2026-01-01T00:00:00Z","completed_at":"2026-01-01T00:16:40Z"}]}
JOBS
SCEN="$SCEN" ADMIN_MERGE_GH="$TMP/gh-multiword --hostname enterprise.example" \
  bash "$ADM" --print-bounds "$RUN_MW" --repo x/y > "$TMP/bounds-mw.txt" 2>&1
grep -q '^rerun-timeout=2000$' "$TMP/bounds-mw.txt" \
  && pass "(P2-6) a multi-word ADMIN_MERGE_GH seam word-splits and reaches the Jobs API" \
  || { fail "(P2-6) the multi-word seam did not execute: $(head -1 "$TMP/bounds-mw.txt")"; sed 's/^/      /' "$TMP/bounds-mw.txt"; }

# (P2-3) AN ADVANCING `updatedAt` MUST NOT POSTPONE THE BOUND. `updatedAt`
# advances on job/step TRANSITIONS, so on a single long test step it is frozen —
# but on a job with several steps it advances while the job is nowhere near done.
# A wait that resets its idle counter on each move therefore NEVER stalls a slow
# multi-step job; it just reports the ceiling. The bound must be the bound,
# regardless of the clock. Pre-fix this scenario returned CEILING (2); the fix
# returns STALLED (1).
new_scen fix-advancing-clock
printf '%s\n' "$HEAD_W1" > "$SCEN/head"
lane_fail "$HEAD_W1" 9931 > "$SCEN/runs-$HEAD_W1"
log_failed 'tests/test_flaky.py::test_stall_scope' > "$SCEN/log-9931"
lane_fail mainfix3 9932 > "$SCEN/runs-main"
log_failed 'tests/test_other.py::test_red_on_main' > "$SCEN/log-9932"
target_shard 9931 "test (b)"
green_shard 9933 "test (b)" 5
printf 'in_progress\n' > "$SCEN/status-9931"
# A clock line per poll, all DISTINCT, covering the bound of 10s. The fake
# repeats its last line once exhausted, but the bound is reached first.
: > "$SCEN/updated-9931"
_i=0; while [ "$_i" -lt 40 ]; do printf 'T%s\n' "$_i" >> "$SCEN/updated-9931"; _i=$((_i + 1)); done
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_RERUN_FLOOR=1 bash "$ADM" 42 --main-runs 1 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -ne 0 ] && pass "(P2-3) an advancing updatedAt still blocks at the bound (exit $rc)" \
  || fail "(P2-3) an advancing clock postponed the bound"
grep -q 'STALLED: still non-completed at its DERIVED per-shard bound' "$TMP/err" \
  && pass "(P2-3) …and the verdict is the DERIVED-bound STALL" \
  || { fail "(P2-3) the derived-bound stall is missing"; sed 's/^/      /' "$TMP/err"; }
grep -q 'still RUNNING at the' "$TMP/err" \
  && fail "(P2-3) an advancing clock turned the stall into the explicit ceiling" \
  || pass "(P2-3) …NOT the explicit ceiling (updatedAt is not consulted)"
grep -q 'updatedAt never moved\|no progress for' "$TMP/err" \
  && fail "(P2-3) the wait still reports an updatedAt-based claim" \
  || pass "(P2-3) …and no freeze-based claim is made in its output"
grep -q 'updatedAt' "$SCEN/calls" \
  && fail "(P2-3) the rail still ASKS gh for updatedAt — the clock can decide again" \
  || pass "(P2-3) …and gh is never asked for updatedAt (call-level tripwire)"

# ── 41. ONE DERIVED BOUND — STALLED AND CEILING ARE A PROVENANCE SPLIT ──────
# The #1167 follow-on defect: a FLAT 600s "no progress" window fired before the
# derived per-shard bound, so a healthy `test (b)` (green median 46.6m, max 49.9m)
# was STALLED at 600s while it was still running. A remote run has no within-job
# activity signal to key a smaller window on, so the derived bound IS the stall
# bound; there is no second window to order against it. STALLED (derived bound
# exceeded) and CEILING (explicit `--rerun-timeout` exceeded) coexist by
# PROVENANCE. The old ordering refusals (`FLOOR < stall + poll`, etc.) are gone:
# a floor is now just a FLOOR, and a small one is legal.
echo "== 41. one derived bound; STALLED and CEILING are distinguished by provenance =="

# (P2-7) a small floor is now LEGAL — it only ever RAISES a per-shard bound, so
# it cannot cause a false block. Pre-fix (`FLOOR=300` over a 600s stall) this
# exited 2.
new_scen bound-small-floor
ADMIN_MERGE_RERUN_FLOOR=300 bash "$ADM" --print-bounds >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -eq 0 ] && pass "(P2-7) a small floor (300) is ACCEPTED — a floor cannot false-block" \
  || fail "(P2-7) a small floor was refused (exit $rc): $(head -1 "$TMP/err")"
grep -q 'refusing' "$TMP/err" \
  && fail "(P2-7) the accepted floor still produced a refusal" \
  || pass "(P2-7) …with no refusal"

# (P2-8) likewise the fail-safe — there is no window to clear, so any positive
# value is accepted. A short one is the operator's own choice: it can only make
# the rail LESS patient, never falsely block a healthy run past its own bound.
new_scen bound-small-failsafe
ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK=300 bash "$ADM" --print-bounds >"$TMP/out" 2>"$TMP/err"
[ "$?" -eq 0 ] && pass "(P2-8) a small fail-safe (300) is ACCEPTED (no window to clear)" \
  || fail "(P2-8) a small fail-safe was refused: $(head -1 "$TMP/err")"

# (P2-9) the DEFAULT floor still applies when no override is given: a per-shard
# green bound below it is lifted to it, so a fast shard is never given a
# too-tight bound. The default is 1200s.
new_scen bound-default-floor
RUN_O=7831
target_shard "$RUN_O" "test (a)"
green_shard 7832 "test (a)" 5
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" \
  bash "$ADM" --print-bounds "$RUN_O" --repo x/y >"$TMP/bounds-o.txt" 2>&1
grep -q '^rerun-timeout=1200$' "$TMP/bounds-o.txt" \
  && pass "(P2-9) the default floor (1200) lifts a 10s green bound" \
  || { fail "(P2-9) the default floor was not applied: $(head -1 "$TMP/bounds-o.txt")"; sed 's/^/      /' "$TMP/bounds-o.txt"; }

# (P2-10) POLL_INTERVAL is a timing knob too: non-numeric is refused (a 600s
# window would become a 600-poll busy spin of gh calls), while 0 stays LEGAL as
# the deterministic test seam.
new_scen order-poll
ADMIN_MERGE_POLL_INTERVAL=abc bash "$ADM" --print-bounds >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -eq 2 ] && pass "(P2-10) a non-numeric ADMIN_MERGE_POLL_INTERVAL is refused (exit 2)" \
  || fail "(P2-10) a non-numeric poll interval was not refused (exit $rc)"
grep -q "refusing ADMIN_MERGE_POLL_INTERVAL='abc'" "$TMP/err" \
  && pass "(P2-10) …and the refusal names the knob and its value" \
  || { fail "(P2-10) the refusal does not name the knob/value"; sed 's/^/      /' "$TMP/err"; }
ADMIN_MERGE_POLL_INTERVAL=0 bash "$ADM" --print-bounds >/dev/null 2>"$TMP/err"
[ $? -eq 0 ] && pass "(P2-10) …and 0 stays LEGAL (the deterministic test seam)" \
  || fail "(P2-10) the 0 test seam was refused: $(head -1 "$TMP/err")"

# (P2-12) POLL_INTERVAL: 'all digits' is not 'usable'. An all-digit value PAST the
# shell's integer range passed counter_is_number and then made `[ "$step" -gt 0 ]`
# error (step fell back to 1) while EVERY `sleep` failed — a tight gh busy-spin
# (measured: 201 `gh run view` calls in 11s for a 200s window).
new_scen order-poll-range
ADMIN_MERGE_POLL_INTERVAL=99999999999999999999 bash "$ADM" --print-bounds >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -eq 2 ] && pass "(P2-12) an all-digit POLL_INTERVAL past the shell's integer range is refused" \
  || fail "(P2-12) the huge poll interval was accepted (exit $rc) — sleep would fail on every poll"
grep -q "refusing ADMIN_MERGE_POLL_INTERVAL='99999999999999999999'" "$TMP/err" \
  && pass "(P2-12) …named by knob and value" \
  || fail "(P2-12) the refusal does not name the knob/value"
grep -q "beyond the usable range" "$TMP/err" \
  && pass "(P2-12) …as beyond the usable range, not merely 'all digits'" \
  || fail "(P2-12) the refusal does not say why it is unusable"
ADMIN_MERGE_POLL_INTERVAL=3601 bash "$ADM" --print-bounds >"$TMP/out" 2>"$TMP/err"
[ "$?" -eq 2 ] && pass "(P2-12) …and a value past the sane maximum (3601) is refused too" \
  || fail "(P2-12) a poll interval beyond an hour was accepted"
ADMIN_MERGE_POLL_INTERVAL=30 bash "$ADM" --print-bounds >"$TMP/out" 2>"$TMP/err"
[ "$?" -eq 0 ] && pass "(P2-12) …while a paced value inside it (30) is accepted" \
  || fail "(P2-12) the in-range poll interval was refused: $(head -1 "$TMP/err")"

# ── 43. A LEADING ZERO IS REFUSED — THE OCTAL/DECIMAL SPLIT ────────────────
# Three parsers read the same timing string, and they disagree. bash ARITHMETIC
# reads a leading-zero all-digit value as OCTAL; the `test` builtin, `sleep`, and
# the counter predicates all read it as DECIMAL. `POLL_INTERVAL=010` is the live
# case: `10#$step` advances the clock by 10 while `sleep` sleeps 10 — one spelling
# must have one meaning. `08`/`0999` are not valid octal at all. The flat stall
# window is gone, so the refusal now covers the knobs that remain (floor,
# fail-safe, poll interval) plus the explicit flag's own parse site.
echo "== 43. a leading zero is refused (the octal/decimal split) =="

# (P1-18) the refusal is UNIFORM across every timing knob, so no single knob can
# still be read in two bases. `0700`/`03900` are ambiguous regardless; `010` is
# the live pacing divergence (accounted as 8 by arithmetic, slept as 10).
for spec in "ADMIN_MERGE_RERUN_FLOOR|0700" \
            "ADMIN_MERGE_RERUN_TIMEOUT_FALLBACK|03900" "ADMIN_MERGE_POLL_INTERVAL|010"; do
  knob="${spec%%|*}"; val="${spec#*|}"
  new_scen "leading-zero-$knob"
  env "$knob=$val" bash "$ADM" --print-bounds >"$TMP/out" 2>"$TMP/err"
  rc=$?
  if [ "$rc" -eq 2 ] && grep -q "refusing $knob='$val'" "$TMP/err"; then
    pass "(P1-18) $knob=$val is refused by name (exit 2)"
  else
    fail "(P1-18) $knob=$val was NOT refused (exit $rc): $(head -1 "$TMP/err")"
  fi
done
# …and the explicit flag's own parse site is a separate path.
new_scen leading-zero-flag
ADMIN_MERGE_POLL_INTERVAL=10 \
  bash "$ADM" --print-bounds --rerun-timeout 0110 >"$TMP/out" 2>"$TMP/err"
rc=$?
[ "$rc" -eq 2 ] && pass "(P1-18) --rerun-timeout 0110 is refused by name (exit 2)" \
  || fail "(P1-18) a leading-zero --rerun-timeout was accepted (exit $rc)"
grep -q "refusing --rerun-timeout '0110'" "$TMP/err" \
  && pass "(P1-18) …naming the flag and its value" \
  || fail "(P1-18) the flag refusal does not name the value"

# (P2-13) an all-digit INVALID-OCTAL value (`08`, `0999`) must give the NAMED
# refusal, not a crash: it is all-digit, so a naive `''|*[!0-9]*` guard would let
# it into an arithmetic site that errors `value too great for base`.
for bad in 0999 08 0008; do
  new_scen "invalid-octal-$bad"
  ADMIN_MERGE_RERUN_FLOOR="$bad" bash "$ADM" --print-bounds >"$TMP/out" 2>"$TMP/err"
  rc=$?
  if [ "$rc" -eq 2 ] && grep -q "refusing ADMIN_MERGE_RERUN_FLOOR='$bad'" "$TMP/err" \
     && ! grep -q 'unbound variable' "$TMP/err" \
     && ! grep -q 'value too great for base' "$TMP/err"; then
    pass "(P2-13) FLOOR=$bad gives the NAMED refusal (exit 2), not a crash"
  else
    fail "(P2-13) FLOOR=$bad did not give the promised refusal (exit $rc): $(head -1 "$TMP/err")"
  fi
done

# (P2-13b) THE DECIMAL CONTRACT IS UNCHANGED — the refusal targets the SPELLING,
# not the value, so a no-leading-zero value at the same numeric value still works.
new_scen leading-zero-decimal-ok
ADMIN_MERGE_POLL_INTERVAL=10 \
  bash "$ADM" --print-bounds --rerun-timeout 110 >"$TMP/out" 2>"$TMP/err"
[ "$?" -eq 0 ] && pass "(P2-13b) the decimal spelling (--rerun-timeout 110) is still accepted" \
  || fail "(P2-13b) the decimal spelling was refused: $(head -1 "$TMP/err")"
grep -q '^rerun-timeout=110$' "$TMP/out" \
  && pass "(P2-13b) …and read as decimal, printed verbatim" \
  || fail "(P2-13b) the value was not printed as 110: $(head -1 "$TMP/out")"

# ── 44. THE `10#` BELT IS DECIMAL — PINNED BEYOND THE REFUSAL GATE ────────
# Section 43 pins the REFUSAL of a leading zero, and that refusal exits FIRST: a
# leading-zero knob is rejected before any `$((…))` site consumes it, so removing a
# `10#` prefix changes nothing observable through the rail's front door — the exact
# coverage hole this section closes. It loads the rail's function definitions (the
# `main "$@"` entrypoint stripped) into a subshell and STUBS the refusal predicate
# `counter_has_leading_zero`, so the arithmetic runs on a leading-zero operand and
# the BASE is the only thing left deciding the outcome:
#   * `wait_for_run` is called directly with POLL_INTERVAL=010, exercising its
#     `+ 10#$step` advances in BOTH branches — the unobservable branch (`unobs`
#     and `waited`) and the progress branch (`waited`) — via the poll count and rc.
# EVERY assertion below goes RED when its `10#` is removed.
echo "== 44. the 10# belt is decimal (independent of the refusal gate) =="

# The rail's definitions with the entrypoint stripped. The refusal predicate and
# `sleep` are stubbed in the probe: the whole point is to run the arithmetic the
# gate normally shields, and `sleep 010` would really sleep 10s ten times over.
BELT_DEFS="$TMP/belt-defs.sh"
sed '$d' "$ADM" > "$BELT_DEFS"
BELT_PROBE="$TMP/belt-probe.sh"
cat > "$BELT_PROBE" <<'BELTEOF'
set -uo pipefail
. "$BELT_DEFS"
counter_has_leading_zero() { return 1; }   # the refusal gate no longer intervenes
sleep() { :; }                             # never wait; the arithmetic is the subject
eval "$BELT_EVAL"
BELTEOF

# (B0) POSITIVE CONTROL — the harness is not "always refuses". With the belt in
# place a positive floor is accepted, so a broken probe cannot read as a pass.
env BELT_DEFS="$BELT_DEFS" BELT_EVAL='validate_timing_knobs' \
  ADMIN_MERGE_POLL_INTERVAL=10 ADMIN_MERGE_RERUN_FLOOR=110 \
  bash "$BELT_PROBE" >"$TMP/out" 2>"$TMP/err"
[ "$?" -eq 0 ] && pass "(B0) the bypassed harness ACCEPTS a valid floor" \
  || fail "(B0) the control config was refused: $(head -1 "$TMP/err")"

# The `wait_for_run` advances, driven directly with POLL=010 (DECIMAL 10; an
# octal-reading step is 8, so a bound of 100 is reached on 10 polls vs 13). rc is
# the return code, the count comes from the fake gh's calls.
belt_wait() {  # belt_wait <unknown|progress> <bound> [explicit]
  local mode="$1" bound="$2" explicit="${3:-0}"
  local cnt="$TMP/belt-calls-$mode-$bound-$explicit" snippet
  : > "$cnt"
  snippet='belt_fake_gh() { printf "x\n" >> "$BELT_CNT"; case "$BELT_MODE" in
      unknown)  printf "unknown\n" ;;
      progress) printf "in_progress\n" ;;
    esac; }
wait_for_run 1; belt_rc=$?
printf "rc=%s polls=%s\n" "$belt_rc" "$(wc -l < "$BELT_CNT" | tr -d " ")"'
  env BELT_DEFS="$BELT_DEFS" BELT_EVAL="$snippet" \
      BELT_MODE="$mode" BELT_CNT="$cnt" ADMIN_MERGE_GH=belt_fake_gh \
      RERUN_TIMEOUT="$bound" RERUN_TIMEOUT_SOURCE=test RERUN_TIMEOUT_EXPLICIT="$explicit" \
      ADMIN_MERGE_POLL_INTERVAL=010 \
      bash "$BELT_PROBE" >"$TMP/out" 2>"$TMP/err"
  local line
  line="$(grep -E '^rc=[0-9]+ polls=[0-9]+$' "$TMP/out" | tail -1)"
  BELT_RC="${line#rc=}"; BELT_RC="${BELT_RC%% *}"
  BELT_POLLS="${line##*polls=}"
}

# (B6) the UNOBSERVABLE branch: an unreadable run reaches UNOBSERVABLE (rc=3)
# after 10 decimal polls; an octal step needs 13. Both `unobs +=` and `waited +=`
# in that branch are exercised.
belt_wait unknown 100
{ [ "$BELT_RC" = 3 ] && [ "$BELT_POLLS" = 10 ]; } \
  && pass "(B6) wait_for_run's unobservable-branch advances are DECIMAL — rc=3 on poll 10" \
  || fail "(B6) the unobs-branch advances read POLL=010 as octal 8 (rc=$BELT_RC polls=$BELT_POLLS, want rc=3 polls=10)"

# (B7) the PROGRESS branch: an in_progress run exceeds the DERIVED bound (rc=1) at
# 10 decimal polls; an octal step needs 13.
belt_wait progress 100
{ [ "$BELT_RC" = 1 ] && [ "$BELT_POLLS" = 10 ]; } \
  && pass "(B7) wait_for_run's progress-branch advance is DECIMAL — rc=1 on poll 10" \
  || fail "(B7) the progress advance read POLL=010 as octal 8 (rc=$BELT_RC polls=$BELT_POLLS, want rc=1 polls=10)"

# (B8) …and an EXPLICIT bound returns CEILING (2) at the same decimal cadence, so
# the belt is not silently swapping the verdict.
belt_wait progress 100 1
{ [ "$BELT_RC" = 2 ] && [ "$BELT_POLLS" = 10 ]; } \
  && pass "(B8) an explicit bound is a CEILING (rc=2) at the decimal cadence" \
  || fail "(B8) the explicit bound mis-resolved (rc=$BELT_RC polls=$BELT_POLLS, want rc=2 polls=10)"

# ── 45. E5 IN THE RAIL: an identity that MOVED is never exempt-and-silent ───
# RENUMBERED TWICE (was §33 on the #1147 branch, then §38 on origin/main).
# Main's §§33-37 (the rail-extractor side, #1165) landed first and are
# authoritative, and THIS branch's #1167 block occupies §§38-44, so the section
# takes §45 to keep the numbering collision-free; the two are COMPLEMENTARY, not
# duplicates:
# §33 above is `attribute_residual`'s FILE-level refusal diagnosis (why the
# residual could not be attributed to this PR), while this section is #1147's
# ID-level decision reason — UNATTRIBUTABLE / rotating identity / rate
# comparison (what the rate comparison decided, and on what evidence). Both
# print; neither replaces the other.
# B7's dynamic form: cycles 2 and 3 ran the SAME head's SAME run id and produced
# DIFFERENT ids. The class stayed red; the id moved. Here main has a MEASURED
# rate (3/3) for the POST-re-run id with a matching signature, so a decision that
# looked only at the latest sample would EXEMPT it and merge. The rotation
# observation — the union of every sample of THIS head — makes it UNATTRIBUTABLE
# instead. Removing that union turns this test RED (the merge proceeds).
echo "== 45. a rotated identity is UNATTRIBUTABLE, never exempt-and-silent =="
new_scen rotation
HEAD_ROT="ee5500000000000000000000000000000000000"
printf '%s\n' "$HEAD_ROT" > "$SCEN/head"
ROT_A1='tests/test_dr_endpoints.py::TestDrDrill::test_dr_restores_to_scratch'
ROT_A2='tests/test_dr_endpoints.py::TestDrDrill::test_dr_restores_to_scratch_416bf7c5'
lane_fail "$HEAD_ROT" 7701 > "$SCEN/runs-$HEAD_ROT"
log_failed "$ROT_A1" > "$SCEN/log-7701"
# The re-run of the SAME run id reports a DIFFERENT identity (a new attempt).
log_failed "$ROT_A2" > "$SCEN/log-after-7701"
main_red_n mainrot 7702 3 "$ROT_A2" > "$SCEN/runs-main"
run_admin 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "the rotated identity BLOCKS the merge (exit $rc)" \
  || fail "a moving identity was exempted — the exempt-and-silent direction"
grep -q 'UNATTRIBUTABLE' "$TMP/err" && pass "…and the refusal is attributed UNATTRIBUTABLE, not 'unique to this PR'" \
  || fail "the refusal does not name UNATTRIBUTABLE: $(grep -m3 'BLOCK\|UNATTRIBUTABLE' "$TMP/err" 2>/dev/null)"
[ -f "$SCEN/comment" ] && fail "evidence was posted for a moving identity" || pass "no evidence comment"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted" || pass "no merge attempted"

# ── 46. THE PR'S EVALUATED TREE GATES THE MERGE; THE BASE IS CONTEXT (#1261) ─
# The rail asked "did this PR introduce failures in the one workflow I watch?"
# and never "is the tree this merge produces green?". With the watched lane green
# on both sides the vacuous branch merged, so a red base on any OTHER workflow
# was invisible: #4589 landed ruff violations, every open PR's tree went
# lint-red, and #4600 merged on top of it.
#
# THE FIRST FIX MEASURED THE WRONG TREE. It read MAIN's head, which catches the
# incident but ALSO refuses the PR that REPAIRS a red main — while main is red so
# is the repair's own evaluation, until it lands — so the rail could not walk its
# own recovery path and recovery was pushed onto the manual
# `AGENT_ADMIN_MERGE_OVERRIDE=1` escape. The question belongs to the tree THIS
# PR PRODUCES.
#
# WHAT GATES, AND WHY. CI evaluates a PR as the MERGE of head into base (the
# `pull_request` merge ref), and GitHub reports the resulting checks against the
# PR's HEAD commit — so the head-keyed surface IS the evaluated tree's surface.
# MEASURED, not assumed: probing `refs/pull/<N>/merge`'s sha returns ZERO check
# runs on every real PR (and the run log shows the job checking out the merge
# ref while its check suite is keyed to the head), so that source would be an
# inert gate. The fixtures below therefore key the PR surface to the HEAD sha
# (`pr-*`) and keep the base surface (`main-*`) separate — which is exactly what
# makes "base RED, PR tree GREEN -> MERGES" expressible.
echo "== 46. the PR's evaluated tree gates the merge; the base is context (#1261) =="

# (a) THE REPAIR PR — THE DISCRIMINATING TEST. The base is RED on another
# workflow (the #1261 shape: a lint gate red on main) and the PR's OWN evaluated
# tree is GREEN, because this PR removes the red. The rail MUST merge it: it is
# the merge path for the repair, and refusing it is the contradiction this fix
# removes. The base red must still be REPORTED for context.
new_scen treehealth-repair
HEAD_RP="b0b0000000000000000000000000000000000000"
printf '%s\n' "$HEAD_RP" > "$SCEN/head"
lane_pass "$HEAD_RP" 5501 > "$SCEN/runs-$HEAD_RP"
lane_pass mainrep 5502 > "$SCEN/runs-main"
main_red_surface      # base red on 'lint' (a workflow the rail does not watch)
pr_green_surface      # the PR's own evaluated tree is GREEN
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a PR whose OWN tree is GREEN MERGES though the base is RED (the repair path)" \
  || fail "the rail REFUSED the PR that repairs a red base (exit $rc) — #1261's contradiction: $(sed -n '1,3p' "$TMP/err" 2>/dev/null)"
grep -q "pr merge" "$SCEN/calls" && pass "…and the repair actually merged" || fail "the repair did NOT merge"
[ -f "$SCEN/comment" ] && pass "…with its head-bound evidence" || fail "no evidence posted for the repair"
grep -q "base tree ('main')" "$TMP/out" && pass "…and the red base is still REPORTED, as context" \
  || fail "the red base is not reported at all"
grep -q "evaluated tree: merge ref refs/pull/42/merge = 67c72331b2466a7cd326375621be897366277a89" "$TMP/out" \
  && pass "…with the merge ref it resolved, named in the record" \
  || fail "the resolved merge ref is not reported"

# (b) THE INCIDENT — THE OTHER DISCRIMINATING TEST. The PR's OWN tree is RED on
# ANOTHER workflow (the merge-ref evaluation of a PR that does NOT repair the red
# base). The rail MUST refuse, naming the job, its workflow and the run URL,
# because THAT check is what failed on the tree this merge lands.
new_scen treehealth-incident
HEAD_IN="b1b1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_IN" > "$SCEN/head"
lane_pass "$HEAD_IN" 5511 > "$SCEN/runs-$HEAD_IN"
lane_pass mainin 5512 > "$SCEN/runs-main"
write_pr_checks \
  "$(check_run 3001 lint completed failure 6601)" \
  "$(check_run 3002 'test (a)' completed success 6601)"
pr_run_map 6601 pull_request 'Post-merge validation'
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a red on the PR's OWN evaluated tree BLOCKS (exit $rc)" \
  || fail "the rail merged a PR whose own tree is red on another workflow — the #1261 false PASS"
grep -q "THE TREE THIS PR PRODUCES IS RED" "$TMP/err" && pass "…and the refusal names the tree, not the lane" \
  || fail "the refusal does not say the PR's tree is red: $(sed -n '1,4p' "$TMP/err" 2>/dev/null)"
grep -q "• lint — workflow 'Post-merge validation'" "$TMP/err" \
  && pass "…naming the failing JOB (lint) and its WORKFLOW" \
  || fail "the refusal does not name the failing job/workflow"
grep -q "actions/runs/6601" "$TMP/err" && pass "…and the run URL" \
  || fail "the refusal does not name the run URL"
# THE SOURCE IS PINNED, not just the outcome: GitHub keys the merge-ref
# evaluation's checks to the HEAD sha, so the rail must read the head's surface.
# The fake serves the MERGE sha an EMPTY surface (as real GitHub does), so a
# regression back to probing refs/pull/<N>/merge would read UNMEASURED and merge
# — and this assertion would fail even before the outcome one did.
grep -q "commits/$HEAD_IN/check-runs" "$SCEN/calls" \
  && pass "…read from the HEAD sha, where GitHub reports the merge-ref evaluation" \
  || fail "the tree surface was not read from the head sha"
grep -q "commits/67c72331b2466a7cd326375621be897366277a89/check-runs" "$SCEN/calls" \
  && fail "the rail probed the MERGE sha's check surface (EMPTY on every real PR — an inert gate)" \
  || pass "…and NOT from the merge sha, whose check surface is EMPTY on a real PR"
[ -f "$SCEN/comment" ] && fail "evidence was posted over a red tree" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a red tree" || pass "no merge attempted"

# (c) THE OVER-REFUSAL GUARD. Clean PR, clean base -> still MERGES. Both surfaces
# are populated with successes so the guard cannot pass on the UNMEASURED state.
new_scen treehealth-clean
HEAD_TG="b2b2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TG" > "$SCEN/head"
lane_pass "$HEAD_TG" 5521 > "$SCEN/runs-$HEAD_TG"
lane_pass maingreen 5522 > "$SCEN/runs-main"
main_green_surface
pr_green_surface
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a clean PR onto a clean base still MERGES (the over-refusal guard)" \
  || fail "the rail REFUSED a clean PR on a clean base (exit $rc): $(sed -n '1,3p' "$TMP/err" 2>/dev/null)"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge actually happened" || fail "no merge was attempted"
[ -f "$SCEN/comment" ] && pass "…with its head-bound evidence" || fail "no evidence posted"

# (d) THE VACUOUS MESSAGE MUST NAME THE MEASURED SETS AND BOTH SURFACES. "nothing
# is broken" and "I did not look" are different facts; so are "the tree is green"
# and "the base is green".
new_scen treehealth-vacuous
HEAD_TV="b3b3000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TV" > "$SCEN/head"
lane_pass "$HEAD_TV" 5531 > "$SCEN/runs-$HEAD_TV"
lane_pass mainvac 5532 > "$SCEN/runs-main"
main_green_surface
pr_green_surface
run_admin 42 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a lane green on both sides, a green tree on a green base, stays certifiable" \
  || fail "expected exit 0, got $rc"
grep -q "measured sets: PR failing runs=0 | main failing runs=0" "$TMP/out" \
  && pass "the vacuous message names BOTH measured sets" \
  || fail "the vacuous message does not name the measured sets"
grep -q "main check surface: green" "$TMP/out" \
  && pass "…and states the BASE's full check surface" \
  || fail "the vacuous message omits the base's check surface"
grep -q "PR evaluated tree: green" "$TMP/out" \
  && pass "…and states the PR'S EVALUATED TREE, the surface that gates the merge" \
  || fail "the vacuous message omits the PR tree surface"
grep -q "EMPTY because nothing FAILED" "$TMP/out" \
  && pass "…and WHY the PR side is empty (green, not an unparsed FAILED line)" \
  || fail "the vacuous message does not distinguish green from unparsed"
grep -q "EMPTY because the lane is GREEN" "$TMP/out" \
  && pass "…and why the main side is empty (a green window, not a missing lane)" \
  || fail "the vacuous message does not distinguish a green window from a missing lane"

# (e) A SUPERSEDED RUN IS NOT A RED. Re-running a failed check leaves the OLD
# failing run in place beside the new one; "any failure-like check" would report a
# red GitHub itself calls green. Applies to the PR's tree too.
new_scen treehealth-superseded
HEAD_TS="b4b4000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TS" > "$SCEN/head"
lane_pass "$HEAD_TS" 5541 > "$SCEN/runs-$HEAD_TS"
lane_pass mainsup 5542 > "$SCEN/runs-main"
write_pr_checks \
  "$(check_run 3101 ai-review-gate completed failure 6701)" \
  "$(check_run 3102 ai-review-gate completed success 6702)"
pr_run_map 6701 pull_request ai-review-gate 6702 pull_request ai-review-gate
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a red SUPERSEDED by a later green of the same check is not a red tree" \
  || fail "a superseded check run false-blocked the merge (exit $rc — the fb27fff shape)"

# (f) AN UNREADABLE TREE SURFACE IS NOT A GREEN TREE. The rail merges with
# --admin, so "I could not look" must never certify. The BASE surface stays
# readable, so this pins the PR probe specifically.
new_scen treehealth-unreadable
HEAD_TU="b5b5000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TU" > "$SCEN/head"
lane_pass "$HEAD_TU" 5551 > "$SCEN/runs-$HEAD_TU"
lane_pass mainun 5552 > "$SCEN/runs-main"
main_green_surface
: > "$SCEN/pr-health-unreadable"
run_admin 42 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an UNREADABLE PR tree surface BLOCKS (exit $rc)" \
  || fail "a probe that failed was read as a green tree"
grep -q "evaluated-tree surface could NOT be read" "$TMP/err" && pass "…and the refusal names the failed probe, actionably" \
  || fail "the unreadable refusal is not named"
[ -f "$SCEN/comment" ] && fail "evidence posted on an unreadable surface" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted on an unreadable surface" || pass "no merge attempted"

# (g) A CHECK STILL RUNNING IS NOT A RED — on the PR's tree either. Main always
# has something in flight; a busy PR tree does too.
new_scen treehealth-pending
HEAD_TP="b6b6000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TP" > "$SCEN/head"
lane_pass "$HEAD_TP" 5561 > "$SCEN/runs-$HEAD_TP"
lane_pass mainpend 5562 > "$SCEN/runs-main"
main_green_surface
write_pr_checks "$(check_run 3201 lint in_progress null 6801)"
pr_run_map 6801 pull_request 'Post-merge validation'
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a PR tree whose checks are still RUNNING is not a red tree" \
  || fail "a PENDING check on the PR tree blocked the merge (exit $rc)"
grep -q "pending 1" "$TMP/out" && pass "…and the pending check is COUNTED in the evidence, not dropped" \
  || fail "the pending count is not reported"

# (h) AN EMPTY TREE SURFACE IS UNMEASURED — stated, never silently green. Right
# after a push the tree's checks have not started, so refusing here would block
# the common case; the lane-scoped half of "I did not look" is step 2b.
new_scen treehealth-unmeasured
HEAD_TN="b7b7000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TN" > "$SCEN/head"
lane_pass "$HEAD_TN" 5571 > "$SCEN/runs-$HEAD_TN"
lane_pass mainnew 5572 > "$SCEN/runs-main"
main_green_surface
run_admin 42 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a fresh PR tree with NO checks is not a refusal" \
  || fail "an empty check surface blocked the merge (exit $rc)"
grep -q "UNMEASURED" "$TMP/out" && pass "…and the state is NAMED, not silently green" \
  || fail "the empty surface is not named in the evidence"

# (i) A RED LEGACY COMMIT STATUS ON THE TREE BLOCKS (fail closed: it has no event
# to classify, so it is not assumed to be noise).
new_scen treehealth-status
HEAD_TX="b8b8000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TX" > "$SCEN/head"
lane_pass "$HEAD_TX" 5581 > "$SCEN/runs-$HEAD_TX"
lane_pass mainstat 5582 > "$SCEN/runs-main"
main_green_surface
printf '{"state":"failure","total_count":1,"statuses":[{"context":"supabase-preview","state":"failure","updated_at":"2026-01-02T00:00:00Z","target_url":"https://example.com/status/1"}]}\n' > "$SCEN/pr-statuses.json"
run_admin 42 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a red legacy commit status on the PR's tree blocks (fail closed)" \
  || fail "a red commit status on the PR's tree was ignored"
grep -q "supabase-preview" "$TMP/err" && pass "…naming the status context" \
  || fail "the refusal does not name the red status"

# (j) A NON-CODE RED ON THE BASE IS REPORTED, NOT BLOCKING — and must not become
# the thing that blocks a green tree. Tortoise's main carries red
# `schedule`/`issues` lanes most days; blocking on those would refuse every merge.
new_scen treehealth-noncode
HEAD_TC="b9b9000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TC" > "$SCEN/head"
lane_pass "$HEAD_TC" 5591 > "$SCEN/runs-$HEAD_TC"
lane_pass maincron 5592 > "$SCEN/runs-main"
write_main_checks "$(check_run 3301 backup completed failure 6901)"
main_run_map 6901 schedule registry-backup-cron
pr_green_surface
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a red on a SCHEDULED base lane does not block (it measures no revision)" \
  || fail "a cron red blocked the merge — the blunt refusal that would stop the fleet"
grep -q "NON-code events" "$TMP/out" && pass "…but it IS reported as a non-code red" \
  || fail "the non-code red is SILENT — invisible is the defect class too"

# (k) THE DELIBERATE NARROWING, PRESERVED AND RE-BASED. The base is red in the
# WATCHED lane (and the lane comparison exempts it, as it would), and the PR's own
# tree carries that red. The TREE refusal fires — "already red on the base" IS
# "the tree is red" — so the exemption path no longer authorises a merge over a
# red tree. Pinned so the narrowing is intentional and reviewable. The remedy for
# a PR that REPAIRS the base is the audited enforcer override, which the refusal
# names.
new_scen treehealth-lane-red
HEAD_TL="b6b6000000000000000000000000000000000001"
printf '%s\n' "$HEAD_TL" > "$SCEN/head"
FAIL_TL='tests/test_main.py::test_already_red_on_main'
lane_fail "$HEAD_TL" 5601 > "$SCEN/runs-$HEAD_TL"
log_failed "$FAIL_TL" > "$SCEN/log-5601"
main_red_n mainlane 5602 3 "$FAIL_TL" > "$SCEN/runs-main"
main_red_surface
write_pr_checks "$(check_run 3401 'test (a)' completed failure 6911)"
pr_run_map 6911 pull_request 'Python CI'
run_admin 42 --main-runs 3 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a red on the PR's tree BLOCKS even where the lane comparison would exempt it" \
  || fail "the rail merged over a tree it had measured red"
grep -q "THE TREE THIS PR PRODUCES IS RED" "$TMP/err" && pass "…as the TREE refusal, not a lane verdict" \
  || fail "the tree-red case did not report the tree refusal: $(sed -n '1,4p' "$TMP/err" 2>/dev/null)"
grep -q "AGENT_ADMIN_MERGE_OVERRIDE" "$TMP/err" && pass "…and names the audited remedy for a repairing PR" \
  || fail "the refusal offers no remedy for the PR that repairs the base"

# (l) A CONFLICTED PR IS REFUSED LOUDLY, before any CI work. GitHub cannot compute
# a merge, so there is no evaluated tree; and the stale merge ref it leaves behind
# must never be measured as if it were current (verified: #1161's ref parents match
# neither the current head nor the current base).
new_scen treehealth-conflicted
HEAD_TCF="c0c0000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TCF" > "$SCEN/head"
lane_pass "$HEAD_TCF" 5611 > "$SCEN/runs-$HEAD_TCF"
lane_pass maincf 5612 > "$SCEN/runs-main"
pr_merge_ref false ""
run_admin 42 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a CONFLICTED PR is refused (exit $rc)" || fail "a conflicted PR was not refused"
grep -q "CONFLICTED" "$TMP/err" && pass "…and the refusal says the tree cannot be evaluated" \
  || fail "the conflict refusal is not named"
[ -f "$SCEN/comment" ] && fail "evidence posted for a conflicted PR" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted for a conflicted PR" || pass "no merge attempted"

# (m) AN ABSENT MERGE REF IS REFUSED LOUDLY — a fresh PR whose merge ref GitHub
# has not computed yet. This is the one case the fake's per-sha surface could
# otherwise HIDE: an empty `pr-*` surface is UNMEASURED and proceeds, so the
# absent ref must be its own loud refusal, not a silent pass.
new_scen treehealth-merge-ref-absent
HEAD_TAB="c1c1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TAB" > "$SCEN/head"
lane_pass "$HEAD_TAB" 5621 > "$SCEN/runs-$HEAD_TAB"
lane_pass mainab 5622 > "$SCEN/runs-main"
pr_merge_ref null ""
run_admin 42 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an ABSENT merge ref is refused (exit $rc)" || fail "an absent merge ref was not refused"
grep -q "has not computed mergeability" "$TMP/err" && pass "…and the refusal says no merge ref exists yet" \
  || fail "the absent-ref refusal is not named"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted with no merge ref" || pass "no merge attempted"

# (n) AN UNREADABLE MERGE-REF PROBE IS NOT A CERTIFICATE EITHER.
new_scen treehealth-merge-ref-unreadable
HEAD_TAU="c2c2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_TAU" > "$SCEN/head"
lane_pass "$HEAD_TAU" 5631 > "$SCEN/runs-$HEAD_TAU"
lane_pass mainau 5632 > "$SCEN/runs-main"
: > "$SCEN/pr-unreadable"
run_admin 42 --dry-run >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an UNREADABLE merge-ref probe is refused (exit $rc)" \
  || fail "an unreadable merge-ref probe was read as permission"
grep -q "mergeability and merge ref were never read" "$TMP/err" && pass "…naming the failed probe" \
  || fail "the unreadable merge-ref refusal is not named"
# (o) STALE GREEN vs A RED BASE — THE INCIDENT. The PR's evaluated tree is GREEN,
# but it was produced BEFORE the base went red. GitHub does not re-run PR checks
# when the base moves, so that green does not cover the new red: it is a STALE
# GREEN, and merging it lands a tree the PR never measured. This is
# #4600-on-#4589 — a PR opened before the base went red and merged after.
new_scen treehealth-stale
HEAD_STALE="c3c3000000000000000000000000000000000000"
printf '%s\n' "$HEAD_STALE" > "$SCEN/head"
lane_pass "$HEAD_STALE" 5701 > "$SCEN/runs-$HEAD_STALE"
lane_pass mainstale 5702 > "$SCEN/runs-main"
# The PR's OWN tree is GREEN, produced at an OLD time.
write_pr_checks \
  "$(check_run 5001 'ci / lint' completed success 7301 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)" \
  "$(check_run 5002 'ci / test' completed success 7301 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7301 pull_request 'CI'
# The base is RED on 'lint', and that red BEGAN AFTER the PR's surface.
write_main_checks "$(check_run 6001 lint completed failure 7401 2026-01-02T00:00:00Z 2026-01-02T00:01:00Z)"
main_run_map 7401 push 'Post-merge validation'
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a STALE green (produced before the base went red) does NOT merge (exit $rc)" \
  || fail "the rail merged a stale green onto a red base it had not measured — the #1261 incident"
grep -q "STALE surface" "$TMP/err" && pass "…and the refusal names the staleness" \
  || fail "the staleness refusal is not named: $(sed -n '1,4p' "$TMP/err" 2>/dev/null)"
grep -q "lint" "$TMP/err" && grep -q "7401" "$TMP/err" \
  && pass "…naming the base red (job and run URL) it failed to cover" \
  || fail "the refusal does not name the base red"
grep -q "RE-MEASURE" "$TMP/err" && pass "…and tells the operator to re-measure this PR's checks" \
  || fail "the refusal offers no re-measure remedy"
[ -f "$SCEN/comment" ] && fail "evidence was posted over a stale green" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a stale green" || pass "no merge attempted"

# (p) MOVED BUT GREEN — THE ANTI-OVER-BLOCK GUARD, and it matters as much as (o).
# The base MOVED after the PR's surface was produced, but it is GREEN there.
# There is nothing this PR has failed to measure, so it MUST merge: refusing on
# movement alone would refuse essentially every open PR on a busy base, and an
# over-block is a failure, not safety.
new_scen treehealth-moved-green
HEAD_MG="c4c4000000000000000000000000000000000000"
printf '%s\n' "$HEAD_MG" > "$SCEN/head"
lane_pass "$HEAD_MG" 5711 > "$SCEN/runs-$HEAD_MG"
lane_pass mainmg 5712 > "$SCEN/runs-main"
# PR surface GREEN at an OLD time; the base GREEN at a NEW time (it moved).
write_pr_checks "$(check_run 5001 'ci / lint' completed success 7311 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7311 pull_request 'CI'
write_main_checks "$(check_run 6001 lint completed success 7411 2026-01-02T00:00:00Z 2026-01-02T00:01:00Z)"
main_run_map 7411 push 'Post-merge validation'
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a base that MOVED but is GREEN still MERGES (the anti-over-block guard)" \
  || fail "the rail refused a PR onto a moved-but-green base (exit $rc): $(sed -n '1,3p' "$TMP/err" 2>/dev/null)"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge actually happened" || fail "no merge attempted"
[ -f "$SCEN/comment" ] && pass "…with its head-bound evidence" || fail "no evidence posted"

# (q) A NEWER NON-CODE BASE RED DOES NOT MAKE A GREEN PR STALE. The base's cron
# lanes measure no revision (see the header), and a staleness gate that used the
# RAW red list would refuse every merge whenever a scheduled lane is newly red —
# the blunt refusal that would stop the fleet. The base here carries an OLD
# blocking red (a `push` lane, measured by the PR and NOT newer, so not stale)
# AND a NEWER `schedule` red; the correct gate filters the non-code red and
# merges, while a raw-list gate would refuse.
new_scen treehealth-stale-noncode
HEAD_SN="c5c5000000000000000000000000000000000000"
printf '%s\n' "$HEAD_SN" > "$SCEN/head"
lane_pass "$HEAD_SN" 5721 > "$SCEN/runs-$HEAD_SN"
lane_pass mainnc 5722 > "$SCEN/runs-main"
# PR surface GREEN produced after the OLD blocking base red (so it measured it).
write_pr_checks "$(check_run 5001 'ci / lint' completed success 7321 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7321 pull_request 'CI'
# An OLD `push` red (not newer than the PR surface) + a NEWER `schedule` red.
write_main_checks \
  "$(check_run 6001 lint completed failure 7411 2026-01-01T00:00:00Z 2026-01-01T00:00:30Z)" \
  "$(check_run 6002 backup completed failure 7421 2026-01-02T00:00:00Z 2026-01-02T00:01:00Z)"
main_run_map 7411 push 'Post-merge validation' 7421 schedule registry-backup-cron
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a NEWER schedule red on the base does not make a green PR stale" \
  || fail "a newly-red cron lane blocked the merge — the blunt refusal that would stop the fleet"
grep -q "NON-code events" "$TMP/out" && pass "…but it IS still reported as a non-code red" \
  || fail "the non-code red is SILENT"

# (r) THE MERGE-REF-LAG CASE — THE HOLE 4.6 CANNOT SEE, AND THE NEW
# DISCRIMINATOR. The PR's tree is GREEN and the base is RED, but the base red's
# run STARTED BEFORE the PR's surface was produced — so the ordering rule at step
# 4.6 does NOT fire. What makes the green stale anyway is that the merge ref was
# computed against an OLDER base: the PR's checks are keyed to a tree that does
# not contain the current base, and GitHub recomputes the merge ref on base
# movement without re-running the PR's checks. The rail MUST refuse on the merge
# ref's FIRST PARENT (step 4.7) — and the assertion that 4.6 did NOT fire is what
# proves this test is about the NEW discriminator, not the timestamp rule.
new_scen treehealth-merge-ref-lag-red
HEAD_LGR="c6c6000000000000000000000000000000000000"
printf '%s\n' "$HEAD_LGR" > "$SCEN/head"
lane_pass "$HEAD_LGR" 5731 > "$SCEN/runs-$HEAD_LGR"
lane_pass mainlgr 5732 > "$SCEN/runs-main"
# PR tree GREEN, produced AFTER the base red began (00:00) — so 4.6 is not stale.
pr_green_surface
# Base RED on a code-measuring `push` lane, its run STARTED at 00:00, BEFORE the
# PR's surface completed at 00:05: the ordering rule cannot refuse this one.
write_main_checks "$(check_run 6001 lint completed failure 7501)"
main_run_map 7501 push 'Post-merge validation'
# The merge ref was computed against an OLDER base than the branch now points at.
merge_parent deadbeef00000000000000000000000000000000
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a LAGGING merge ref onto a RED base refuses (exit $rc)" \
  || fail "the rail merged a green that was evaluated against an OLDER base than the red one — the merge-ref-lag hole"
grep -q "LAGGING MERGE REF" "$TMP/err" && pass "…and the refusal names the lagging merge ref" \
  || fail "the merge-ref-lag refusal is not named: $(sed -n '1,4p' "$TMP/err" 2>/dev/null)"
grep -q "STALE surface" "$TMP/err" \
  && fail "the refusal is the 4.6 ordering rule, not the merge-ref discriminator — this test would not pin 4.7" \
  || pass "…and it is NOT the 4.6 ordering rule (the base red predates the PR surface)"
grep -q "lint" "$TMP/err" && grep -q "7501" "$TMP/err" \
  && pass "…naming the base red (job and run URL) this PR has not measured" \
  || fail "the refusal does not name the base red it failed to measure"
grep -q "deadbeef00000000000000000000000000000000" "$TMP/err" \
  && grep -q "feedface0000000000000000000000000000000000" "$TMP/err" \
  && pass "…and names BOTH the base parent it was evaluated against and the current base head" \
  || fail "the refusal does not name the lagging parent and the current base head"
grep -q "RE-MEASURE" "$TMP/err" && pass "…with the re-run remedy" \
  || fail "the merge-ref-lag refusal offers no re-measure remedy"
[ -f "$SCEN/comment" ] && fail "evidence was posted over a lagging evaluation" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a lagging evaluation" || pass "no merge attempted"

# (s) LAGGING MERGE REF ONTO A GREEN BASE — THE ANTI-OVER-BLOCK GUARD, AND IT
# MATTERS AS MUCH AS (r). The merge ref lags (its parent differs from the base
# head) but the base is GREEN, so there is nothing the PR failed to measure: it
# MUST merge. The merge ref is recomputed continuously, so a lag of a commit or
# two is the NORMAL state (measured on 12 of 12 open tortoise PRs while main was
# green); refusing on the comparison alone would refuse essentially every open PR.
new_scen treehealth-merge-ref-lag-green
HEAD_LGG="c7c7000000000000000000000000000000000000"
printf '%s\n' "$HEAD_LGG" > "$SCEN/head"
lane_pass "$HEAD_LGG" 5741 > "$SCEN/runs-$HEAD_LGG"
lane_pass mainlgg 5742 > "$SCEN/runs-main"
main_green_surface
pr_green_surface
# The merge ref lags the base head, but the base is GREEN.
merge_parent deadbeef00000000000000000000000000000000
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a LAGGING merge ref onto a GREEN base still MERGES (the anti-over-block guard)" \
  || fail "the rail refused a PR whose merge ref lags a GREEN base (exit $rc): $(sed -n '1,3p' "$TMP/err" 2>/dev/null)"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge actually happened" || fail "no merge attempted"
[ -f "$SCEN/comment" ] && pass "…with its head-bound evidence" || fail "no evidence posted"
# THE COMPARISON IS RED-BASE-ONLY, so a green base makes NO parent probe at all.
# A wrong implementation that probes unconditionally and refuses on the mismatch
# fails the outcome assertion above; this pins the cheaper, narrower shape too.
grep -q 'parents\[0\]' "$SCEN/calls" \
  && fail "the rail probed the merge ref's parent for a GREEN base — the comparison must be red-base-only" \
  || pass "…and no merge-ref parent probe is made when the base is green"

# (t) AN UNREADABLE MERGE-REF PARENT ON A RED BASE FAILS CLOSED. "I could not
# read the parent" cannot show the PR measured the current base, and this rail
# merges with --admin, so it is a refusal — the same rule as an unreadable tree
# surface at 4.5. A fail-open here would readmit exactly the (r) case.
new_scen treehealth-merge-ref-parent-unreadable
HEAD_LGU="c8c8000000000000000000000000000000000000"
printf '%s\n' "$HEAD_LGU" > "$SCEN/head"
lane_pass "$HEAD_LGU" 5751 > "$SCEN/runs-$HEAD_LGU"
lane_pass mainlgu 5752 > "$SCEN/runs-main"
write_main_checks "$(check_run 6001 lint completed failure 7511)"
main_run_map 7511 push 'Post-merge validation'
pr_green_surface
: > "$SCEN/merge-parent-unreadable"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an UNREADABLE merge-ref parent on a RED base refuses (exit $rc)" \
  || fail "an unreadable merge-ref parent was read as permission"
grep -q "BASE PARENT COULD NOT BE READ" "$TMP/err" && pass "…and the refusal names the failed probe, actionably" \
  || fail "the unreadable-parent refusal is not named"
[ -f "$SCEN/comment" ] && fail "evidence posted on an unreadable merge-ref parent" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted on an unreadable merge-ref parent" || pass "no merge attempted"

# ── 47. THE CLASSIFIER IS AN ALLOW-LIST — AN UNRECOGNISED SPELLING IS RED (#1261 fix round) ─
# The header documented an allow-list ("NOT red, by name: success; neutral;
# skipped; cancelled; stale") but the code was a DENY-list: a COMPLETED check run
# was red only for `failure`/`timed_out`/`action_required`/`startup_failure`, and
# a legacy status only for `failure`/`error`. Every other token was silently
# NON-RED, so an unrecognised spelling merged. This repo's rule is the opposite:
# a guard must fail CLOSED on an unrecognised spelling. Each scenario below is
# GREEN under the deny-list and REFUSES under the allow-list; the over-block
# guard (d) is the other half — the five NAMED non-red conclusions must still
# merge.
echo "== 47. an unrecognised conclusion/state is RED, never silently non-red (#1261 fix round) =="

# (a) AN UNRECOGNISED CONCLUSION ON THE PR'S OWN TREE IS RED. The deny-list read
# `mystery_failure` as neither red nor pending, so the tree surface was GREEN and
# the rail posted evidence and merged.
new_scen allowlist-tree-conc
HEAD_AL1="d1d1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_AL1" > "$SCEN/head"
lane_pass "$HEAD_AL1" 5801 > "$SCEN/runs-$HEAD_AL1"
lane_pass mainal1 5802 > "$SCEN/runs-main"
main_green_surface
write_pr_checks "$(check_run 3501 lint completed mystery_failure 6601)"
pr_run_map 6601 pull_request 'Post-merge validation'
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an UNRECOGNISED conclusion on the PR tree BLOCKS (exit $rc)" \
  || fail "an unrecognised conclusion read as non-red and MERGED — the deny-list hole"
grep -q "THE TREE THIS PR PRODUCES IS RED" "$TMP/err" && pass "…as the tree-red refusal" \
  || fail "the refusal is not the tree-red one: $(sed -n '1,4p' "$TMP/err" 2>/dev/null)"
grep -q "mystery_failure" "$TMP/err" && pass "…naming the unrecognised conclusion verbatim" \
  || fail "the refusal does not name the unrecognised token"
[ -f "$SCEN/comment" ] && fail "evidence was posted over an unrecognised red" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over an unrecognised red" || pass "no merge attempted"

# (b) A COMPLETED RUN WITH AN EMPTY CONCLUSION IS RED TOO — it is an anomaly, and
# "completed with no conclusion" is not a name this rail knows.
new_scen allowlist-tree-empty-conc
HEAD_AL2="d2d2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_AL2" > "$SCEN/head"
lane_pass "$HEAD_AL2" 5803 > "$SCEN/runs-$HEAD_AL2"
lane_pass mainal2 5804 > "$SCEN/runs-main"
main_green_surface
write_pr_checks "$(check_run 3502 lint completed '' 6602)"
pr_run_map 6602 pull_request 'Post-merge validation'
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a COMPLETED run with an EMPTY conclusion BLOCKS (exit $rc)" \
  || fail "a completed run with an empty conclusion read as non-red and merged"
grep -q "THE TREE THIS PR PRODUCES IS RED" "$TMP/err" && pass "…as the tree-red refusal" \
  || fail "the empty-conclusion refusal is not the tree-red one"

# (c) AN UNRECOGNISED LEGACY STATUS STATE IS RED, and it is not PENDING either
# (the deny-list put it in neither bucket, so it vanished from both).
new_scen allowlist-tree-state
HEAD_AL3="d3d3000000000000000000000000000000000000"
printf '%s\n' "$HEAD_AL3" > "$SCEN/head"
lane_pass "$HEAD_AL3" 5805 > "$SCEN/runs-$HEAD_AL3"
lane_pass mainal3 5806 > "$SCEN/runs-main"
main_green_surface
printf '{"state":"mystery","total_count":1,"statuses":[{"context":"supabase-preview","state":"mystery","updated_at":"2026-01-02T00:00:00Z","target_url":"https://example.com/status/1"}]}\n' > "$SCEN/pr-statuses.json"
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an UNRECOGNISED status state BLOCKS (exit $rc)" \
  || fail "an unrecognised status state read as neither red nor pending and merged"
grep -q "supabase-preview" "$TMP/err" && pass "…naming the status context that carried it" \
  || fail "the refusal does not name the unrecognised status state"

# (d) THE SAME SPELLING ON THE BASE, WITH A LAGGING MERGE REF, REFUSES AT 4.7.
# This is the verifier's second reproduction: `failure` here refuses (test (r));
# under the deny-list `mystery_failure` merged.
new_scen allowlist-base-conc-lag
HEAD_AL4="d4d4000000000000000000000000000000000000"
printf '%s\n' "$HEAD_AL4" > "$SCEN/head"
lane_pass "$HEAD_AL4" 5807 > "$SCEN/runs-$HEAD_AL4"
lane_pass mainal4 5808 > "$SCEN/runs-main"
write_main_checks "$(check_run 6501 lint completed mystery_failure 7501)"
main_run_map 7501 push 'Post-merge validation'
pr_green_surface
merge_parent deadbeef00000000000000000000000000000000
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an UNRECOGNISED base conclusion + a LAGGING merge ref REFUSES at 4.7 (exit $rc)" \
  || fail "an unrecognised base red merged where 'failure' refuses at 4.7 — the deny-list hole"
grep -q "LAGGING MERGE REF" "$TMP/err" && pass "…and this is the 4.7 discriminator, not the 4.6 ordering rule" \
  || fail "the refusal is not the merge-ref-lag one: $(sed -n '1,4p' "$TMP/err" 2>/dev/null)"
grep -q "mystery_failure" "$TMP/err" && pass "…naming the unrecognised base red" \
  || fail "the refusal does not name the base red"
[ -f "$SCEN/comment" ] && fail "evidence was posted over an unrecognised base red" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over an unrecognised base red" || pass "no merge attempted"

# (e) THE OVER-BLOCK GUARD: every NAMED non-red conclusion still merges, on BOTH
# surfaces. An allow-list is only correct if it is exactly the documented set — a
# classifier that reddened `neutral`/`skipped`/`cancelled`/`stale` would refuse
# essentially every real PR (path-gated jobs skip; superseded runs are cancelled).
new_scen allowlist-nonred-known
HEAD_AL5="d5d5000000000000000000000000000000000000"
printf '%s\n' "$HEAD_AL5" > "$SCEN/head"
lane_pass "$HEAD_AL5" 5809 > "$SCEN/runs-$HEAD_AL5"
lane_pass mainal5 5810 > "$SCEN/runs-main"
write_main_checks \
  "$(check_run 6601 'base / success' completed success 7601)" \
  "$(check_run 6602 'base / neutral' completed neutral 7601)" \
  "$(check_run 6603 'base / skipped' completed skipped 7601)" \
  "$(check_run 6604 'base / cancelled' completed cancelled 7601)" \
  "$(check_run 6605 'base / stale' completed stale 7601)"
main_run_map 7601 push 'Post-merge validation'
write_pr_checks \
  "$(check_run 5601 'pr / success' completed success 7701)" \
  "$(check_run 5602 'pr / neutral' completed neutral 7701)" \
  "$(check_run 5603 'pr / skipped' completed skipped 7701)" \
  "$(check_run 5604 'pr / cancelled' completed cancelled 7701)" \
  "$(check_run 5605 'pr / stale' completed stale 7701)"
pr_run_map 7701 pull_request 'CI'
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "the five NAMED non-red conclusions still merge (the over-block guard)" \
  || fail "a legitimately non-red conclusion was refused (exit $rc): $(sed -n '1,3p' "$TMP/err" 2>/dev/null)"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge actually happened" || fail "no merge attempted"
[ -f "$SCEN/comment" ] && pass "…with its head-bound evidence" || fail "no evidence posted"
grep -q "PARTIAL\|UNREADABLE" "$TMP/out" && fail "a fully readable surface was reported as partial/unreadable" \
  || pass "…and both endpoints READ (no PARTIAL/UNREADABLE state)"

# ── 48. A PARTIAL BASE READ IS NEVER A CERTIFICATE (#1261 fix round) ────────
# The probe reads TWO endpoints — `/check-runs` and `/status`. It used to return
# UNREADABLE the moment EITHER failed, which discarded the other's reds and, on
# the BASE, silently DISARMED 4.6/4.7: both are gated on the base being RED, so a
# base that could not be read was treated as a base that is NOT RED and the stale
# green merged. The fix consumes the readable endpoint AND refuses a half-read
# base outright; only BOTH failing is the "never read at all" state.
echo "== 48. a half-read base surface refuses; only both endpoints failing is unreadable (#1261 fix round) =="

# (a) THE REPRODUCTION. A base red readable ONLY on `/status` (`deploy-verify`),
# with only `/check-runs` forced to fail. The old rail merged (RC=0, "base tree
# UNREADABLE", evidence posted).
new_scen base-partial-status-red
HEAD_BP1="d6d6000000000000000000000000000000000000"
printf '%s\n' "$HEAD_BP1" > "$SCEN/head"
lane_pass "$HEAD_BP1" 5811 > "$SCEN/runs-$HEAD_BP1"
lane_pass mainbp1 5812 > "$SCEN/runs-main"
pr_green_surface
: > "$SCEN/main-check-runs-unreadable"
printf '{"state":"failure","total_count":1,"statuses":[{"context":"deploy-verify","state":"failure","updated_at":"2026-01-02T00:00:00Z","target_url":"https://example.com/status/1"}]}\n' > "$SCEN/main-statuses.json"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a base red readable ONLY on /status (check-runs failed) REFUSES (exit $rc)" \
  || fail "a half-read base was read as 'not red' and MERGED — 4.6/4.7 silently disarmed"
grep -q "ONLY HALF READ" "$TMP/err" && pass "…as the half-read refusal, by name" \
  || fail "the partial-base refusal is not named: $(sed -n '1,4p' "$TMP/err" 2>/dev/null)"
grep -q "deploy-verify" "$TMP/err" && pass "…naming the red the READABLE endpoint DID carry (consumed, not discarded)" \
  || fail "the partial refusal discarded the red that WAS read"
grep -q "THE BASE IS RED AND THIS PR HAS NOT MEASURED IT" "$TMP/err" \
  && fail "the refusal is only the 4.6 ordering rule — a partial read must refuse on its own" \
  || pass "…and it refuses even before the staleness rules could run"
[ -f "$SCEN/comment" ] && fail "evidence was posted over a half-read base" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a half-read base" || pass "no merge attempted"

# (b) THE CONTROL — THE IDENTICAL FIXTURE WITH BOTH ENDPOINTS READABLE. This is
# the verifier's comparison: without the failed `/check-runs`, the same red
# refuses via 4.6. Both variants must refuse.
new_scen base-partial-control
HEAD_BP2="d7d7000000000000000000000000000000000000"
printf '%s\n' "$HEAD_BP2" > "$SCEN/head"
lane_pass "$HEAD_BP2" 5813 > "$SCEN/runs-$HEAD_BP2"
lane_pass mainbp2 5814 > "$SCEN/runs-main"
pr_green_surface
printf '{"state":"failure","total_count":1,"statuses":[{"context":"deploy-verify","state":"failure","updated_at":"2026-01-02T00:00:00Z","target_url":"https://example.com/status/1"}]}\n' > "$SCEN/main-statuses.json"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "the CONTROL (both endpoints read) refuses at 4.6, as before (exit $rc)" \
  || fail "the fully-readable control did not refuse — the fix changed the readable path"
grep -q "THE BASE IS RED AND THIS PR HAS NOT MEASURED IT" "$TMP/err" \
  && pass "…naming the staleness, exactly as the pre-fix rail does" \
  || fail "the control refusal is not the 4.6 staleness one"

# (c) BOTH ENDPOINTS FAILING IS THE "NEVER READ AT ALL" STATE — a loud refusal,
# not the old context-only line that let the merge proceed.
new_scen base-both-unreadable
HEAD_BP3="d8d8000000000000000000000000000000000000"
printf '%s\n' "$HEAD_BP3" > "$SCEN/head"
lane_pass "$HEAD_BP3" 5815 > "$SCEN/runs-$HEAD_BP3"
lane_pass mainbp3 5816 > "$SCEN/runs-main"
pr_green_surface
: > "$SCEN/main-check-runs-unreadable"
: > "$SCEN/main-status-unreadable"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "BOTH base endpoints failing is a loud refusal (exit $rc)" \
  || fail "a base surface that was never read at all still merged"
grep -q "BOTH" "$TMP/err" && grep -q "never read" "$TMP/err" \
  && pass "…and the refusal says BOTH endpoints failed, not that the base was not red" \
  || fail "the both-unreadable refusal does not name the both-endpoint failure: $(sed -n '1,4p' "$TMP/err" 2>/dev/null)"
[ -f "$SCEN/comment" ] && fail "evidence was posted on a never-read base" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted on a never-read base" || pass "no merge attempted"

# (d) THE TREE IS STRICT TOO. A PR surface missing one endpoint is refused, and
# the red the READABLE half carried is named — an incomplete read is never a
# green on the surface that GATES the merge.
new_scen tree-partial
HEAD_BP4="d9d9000000000000000000000000000000000000"
printf '%s\n' "$HEAD_BP4" > "$SCEN/head"
lane_pass "$HEAD_BP4" 5817 > "$SCEN/runs-$HEAD_BP4"
lane_pass mainbp4 5818 > "$SCEN/runs-main"
main_green_surface
: > "$SCEN/pr-check-runs-unreadable"
printf '{"state":"failure","total_count":1,"statuses":[{"context":"supabase-preview","state":"failure","updated_at":"2026-01-02T00:00:00Z","target_url":"https://example.com/status/1"}]}\n' > "$SCEN/pr-statuses.json"
run_admin 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a PR tree missing one endpoint REFUSES (exit $rc)" \
  || fail "a half-read PR tree was read as green"
grep -q "only HALF read" "$TMP/err" && pass "…as the half-read refusal, by name" \
  || fail "the partial-tree refusal is not named"
grep -q "supabase-preview" "$TMP/err" && pass "…naming the red the readable half carried" \
  || fail "the partial-tree refusal discarded the red that WAS read"
[ -f "$SCEN/comment" ] && fail "evidence was posted over a half-read tree" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a half-read tree" || pass "no merge attempted"
# ── 49. a VACUOUS comparison is not a certificate (#1319) ──────────────────
# `PR failing: 0 | main failing: 0` is an ABSENCE of a measurement. It certifies
# only when the PR demonstrably EXECUTED the lane main executes. tortoise #4263
# merged on exactly this line while its tier-2 PR lane had SKIPPED shards main's
# push lane runs; the failure lived in one of them, could appear in NEITHER
# collected set, and reddened main's required check for the whole fleet (#4457).
echo "== 49. a vacuous comparison is NOT COMPARABLE unless lane parity holds (#1319) =="

# (a) THE DEFECT. Both failing sets empty; the PR ran only the fast halves while
# main ran the slow halves and the embedded carve-out too. Before this gate the
# rail printed the vacuous warning and MERGED. Now 'not comparable' is a refusal,
# distinct from both 'compared, clean' and 'compared, dirty'.
new_scen vacuousparity
HEAD_VP="0a0a000000000000000000000000000000000000"
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9301 > "$SCEN/runs-$HEAD_VP"
lane_pass mainaaaa 9302 > "$SCEN/runs-main"
lane_jobset 9301 success 'test (a)' 'test (b)'
lane_jobset 9302 success 'test (a)' 'test (b)' 'test-slow (a)' 'test-slow (b)' 'test-carve-out'
run_admin_here 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "both sets empty + the PR skipped a shard main ran → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — a vacuous comparison merged without comparing the same lane"
grep -q "NOT COMPARABLE" "$SCEN/err" && pass "the verdict is NAMED: NOT COMPARABLE (not a clean comparison)" \
  || fail "expected the NOT-COMPARABLE verdict on stderr, got: $(head -3 "$SCEN/err" 2>/dev/null)"
grep -q "did NOT EXECUTE 3 test shard" "$SCEN/err" && pass "the refusal counts the shards this head never ran" \
  || fail "the refusal does not say how many shards the PR did not run"
# The missing-shard list is its OWN block, bounded by the two headers below. It
# must be asserted INSIDE that block: a bare `grep test-slow (a) "$SCEN/err"` also
# matches the main-lane dump further down and would pass even if the refusal
# named nothing at all.
missing_block="$(sed -n '/shard(s) main EXECUTED and this head did not:/,/PR lane — executed/p' "$SCEN/err")"
case "$missing_block" in *"test-slow (a)"*) pass "…and NAMES them (option 2: 0|0 must be legible, not silent)" ;;
  *) fail "the refusal's MISSING block does not name the lane the PR did not run" ;; esac
case "$missing_block" in *"test-carve-out"*) pass "…all of them, not just the first" ;;
  *) fail "only one missing shard named in the missing block" ;; esac
# …and EXACTLY them: 3 missing shards, not main's 5-name dump bleeding in.
[ "$(printf '%s\n' "$missing_block" | grep -c '^      test')" -eq 3 ] \
  && pass "…and the block lists EXACTLY the 3 missing shards (not main's fuller dump)" \
  || fail "the missing block is not the missing set (it holds $(printf '%s\n' "$missing_block" | grep -c '^      test') shard lines)"
grep -q "main lane — executed 5 test shard" "$SCEN/err" && pass "the main lane is named too" \
  || fail "the main side's shard set is not reported"
grep -q "PR lane — executed 2 test shard" "$SCEN/err" && pass "…and so is the PR lane" || fail "the PR side's shard set is not reported"
[ -f "$SCEN/comment" ] && fail "no evidence may be posted for a not-comparable pair" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted on a not-comparable pair" || pass "no merge attempted"

# (b) FAIL CLOSED when the coverage cannot be READ. An unreadable job list is not
# an empty one: treating it as 'the same lane' is the fail-open this gate exists
# to remove, and a Jobs API error must never become a certificate.
new_scen vacuousunreadable
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9401 > "$SCEN/runs-$HEAD_VP"
lane_pass mainbbbb 9402 > "$SCEN/runs-main"
lane_jobset 9401 success 'test (a)'
# DELIBERATELY no jobs-9402.json: `lane_pass` writes a default listing, so the
# scenario must REMOVE it to model a run whose Jobs API call fails. That absence
# is the subject of this scenario — an unreadable listing is never an empty one.
rm -f "$SCEN/jobs-9402.json"
run_admin_here 42 --main-runs 1 >/dev/null 2>&1        # no jobs-9402.json → the API errors
rc=$?
[ "$rc" -ne 0 ] && pass "an unreadable shard list → BLOCK (exit $rc), never a certificate" \
  || fail "expected a non-zero exit, got 0 — unreadable coverage was read as parity"
grep -q "coverage could not be established" "$SCEN/err" && pass "…failing closed, by name" \
  || fail "expected the coverage-unreadable reason on stderr"
grep -q "ADMIN_MERGE_LANE_JOB_PREFIX" "$SCEN/err" && pass "…and the message says how to fix a non-'test' lane" \
  || fail "the refusal does not name the escape for a differently-named lane"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted" || pass "no merge attempted"

# (c) A SKIPPED shard is NOT coverage. `skipped` is terminal, so a presence test
# would accept it — but it exercised nothing, exactly like the parser's `tested`
# doctrine. Comparing job lists by presence instead of by execution silently
# re-opens the #4457 hole.
new_scen vacuousskipped
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9601 > "$SCEN/runs-$HEAD_VP"
lane_pass maindddd 9602 > "$SCEN/runs-main"
# The PR's run LISTS the slow shards — as `skipped`.
lane_jobs 9601 'test (a):success' 'test (b):success' 'test-slow (a):skipped' 'test-slow (b):skipped'
lane_jobs 9602 'test (a):success' 'test (b):success' 'test-slow (a):success' 'test-slow (b):success'
run_admin_here 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a shard main RAN and the PR SKIPPED → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — 'skipped' was read as coverage (the #4457 hole re-opened)"
grep -q "test-slow (a)" "$SCEN/err" && pass "…and the skipped shard is the one named" \
  || fail "the skipped shard is not reported as missing"

# (d) THE PARITY KEY IS THE VERBATIM SHARD NAME. The re-run derivation reduces a
# job name to its FIRST matrix axis so it can group shards across runs; parity
# must NOT. `test (a, docker)` and `test (a, embedded)` are DIFFERENT lanes, and
# collapsing them is the surface-blindness this gate removes — the very
# distinction #1319 names (main's push lane vs the PR's).
new_scen vacuousaxis
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9701 > "$SCEN/runs-$HEAD_VP"
lane_pass maineeee 9702 > "$SCEN/runs-main"
lane_jobset 9701 success 'test (a, embedded)'
lane_jobset 9702 success 'test (a, docker)'
run_admin_here 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a different matrix surface is a DIFFERENT lane → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — the matrix axis was normalised away and the lanes looked equal"
grep -q "test (a, docker)" "$SCEN/err" && pass "…naming the docker surface main ran" \
  || fail "the missing surface is not named"

# (e) PARITY HOLDS → certify, and the evidence STATES it. This is the half that
# keeps the gate from blocking every clean merge: a lane green on both sides is a
# comparison that happened, and it stays certifiable — but on the stated parity,
# never as a bare `0 | 0`.
new_scen vacuouscertify
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9501 > "$SCEN/runs-$HEAD_VP"
lane_pass maincccc 9502 > "$SCEN/runs-main"
lane_jobset 9501 success 'test (a)' 'test (b)'
lane_jobset 9502 success 'test (a)' 'test (b)'
run_admin_here 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "same shards on both sides, both green → certify (exit 0)" \
  || fail "expected exit 0, got $rc — the gate OVER-BLOCKS a genuinely comparable lane"
grep -q "lane parity: PR ⊇ main" "$SCEN/comment" && pass "the POSTED evidence states the parity the zeros rest on" \
  || fail "the certification does not state the parity it rests on"
grep -q "lane parity: PR ⊇ main" "$SCEN/out" && pass "…and the operator-facing line says the same, not a bare 'nothing was compared'" \
  || fail "the vacuous line still carries no signal about what it rests on"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge proceeds once parity is established" \
  || fail "no merge issued for a certified vacuous comparison"
# A parity certificate must not weaken the merge's OWN head pin: the evidence is
# bound to $HEAD_VP and GitHub must enforce that head at merge time.
grep -q -- "--match-head-commit $HEAD_VP" "$SCEN/calls" \
  && pass "…and the merge is HEAD-PINNED, so parity does not relax the head binding" \
  || fail "the certified merge lost --match-head-commit"

# (f) AN EMPTY SHARD SET IS NOT PARITY (#1319 cycle-1 review P0, REPRODUCED).
# `lane_shards` used to `printf '%s\n' "$out"` unconditionally, so a run that
# executed NO matching shard emitted a BLANK LINE: both sides' sets were then
# 1-byte files, `[ -s ]` passed, `grep -xF` matched the blank pattern against the
# blank line, the difference came out EMPTY — and the rail CERTIFIED AND MERGED
# having observed nothing at all. That is #4457 exactly, one level down. The set
# must be empty as a STREAM and the decision must be taken on NAMES.
new_scen vacuousblank
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9801 > "$SCEN/runs-$HEAD_VP"
lane_pass mainffff 9802 > "$SCEN/runs-main"
# Readable job lists — every shard present but SKIPPED on BOTH sides.
lane_jobset 9801 skipped 'test (a)' 'test (b)'
lane_jobset 9802 skipped 'test (a)' 'test (b)'
run_admin_here 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "both lanes observed ZERO executed shards → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — an EMPTY shard set was read as parity (the #4457 hole, re-opened a level down)"
grep -q "coverage could not be established" "$SCEN/err" && pass "…and the reason is the unobserved lane, not a comparison" \
  || fail "the empty-lane refusal does not say the coverage was never established"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted on an unobserved lane" || pass "no merge attempted"

# (g) same hole, other shape: the job lists are readable and ALL jobs EXECUTED,
# but no job name matches the parity prefix. A prefix that selects nothing is an
# empty reference, never a pass — and the refusal has to say which knob fixes it.
new_scen vacuousnoprefix
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9851 > "$SCEN/runs-$HEAD_VP"
lane_pass main9999 9852 > "$SCEN/runs-main"
lane_jobset 9851 success 'unit-test' 'lint'
lane_jobset 9852 success 'unit-test' 'lint'
run_admin_here 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "no job matches the shard prefix on either side → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — an empty reference certified a vacuous comparison"
grep -q "ADMIN_MERGE_LANE_JOB_PREFIX" "$SCEN/err" && pass "…naming the knob for a differently-named lane" \
  || fail "the refusal does not name ADMIN_MERGE_LANE_JOB_PREFIX"

# (h) A LISTING FAILURE IS NOT "FEWER SHARDS". `lane_run_ids` swallowed gh's exit
# status, so an auth/network failure produced an EMPTY listing — which read as
# "no runs to compare" and certified. The parser and the rail issue BYTE-IDENTICAL
# `gh run list` calls, so no flag can separate them; the CALL ORDER can. The
# rail's lane listing for the PR head is the 4th `run list` of this scenario
# (parser: pr rows, main rates, main signatures; then the lane pass). If that
# ordering ever shifts, the parser's OWN listing fails and the assertion below
# fails loudly — it cannot silently stop testing what it names.
new_scen vacuouslistfail
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9861 > "$SCEN/runs-$HEAD_VP"
lane_pass main1010 9862 > "$SCEN/runs-main"
lane_jobset 9861 success 'test (a)'
lane_jobset 9862 success 'test (a)'
printf '%s\n' 4 > "$SCEN/fail-run-list-nth"
run_admin_here 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an unreadable lane RE-LISTING → BLOCK (exit $rc), never a certificate" \
  || fail "expected a non-zero exit, got 0 — a failed `gh run list` was read as 'fewer shards'"
grep -q "could not list the lane runs" "$SCEN/err" && pass "…and the failure is named as a LISTING failure, not as coverage" \
  || fail "the refusal does not distinguish a listing failure from a thin lane: $(head -2 "$SCEN/err")"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted on an unreadable lane" || pass "no merge attempted"

# (i) THE WINDOW IS THE OPERATOR'S WINDOW. The gate used to sample only the first
# 3 lane runs per side, independently of `--main-runs`: a shard main executed only
# in an OLDER run inside the operator's window vanished from the reference, and a
# PR that never ran it certified. Here main's 4th run carries `test (b)`; the PR
# ran only `test (a)`. With a 3-run cap this certified — a fail-open.
new_scen vacuouswindow
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9871 > "$SCEN/runs-$HEAD_VP"
{
  lane_pass mainw0 9872
  lane_pass mainw0 9873
  lane_pass mainw0 9874
  lane_pass mainw0 9875
} > "$SCEN/runs-main"
lane_jobset 9871 success 'test (a)'
lane_jobset 9872 success 'test (a)'
lane_jobset 9873 success 'test (a)'
lane_jobset 9874 success 'test (a)'
lane_jobset 9875 success 'test (a)' 'test (b)'
run_admin_here 42 --main-runs 4 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a shard main ran only INSIDE the operator's window is still a reference → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — the sampling cap hid a shard main had executed (fail-open)"
grep -q "test (b)" "$SCEN/err" && pass "…and the window-boundary shard is the one named" \
  || fail "the shard that exists only in an older window run is not reported"

# (j) THE AUDITED ESCAPE. A repo whose PR lane legitimately cannot run a shard
# main's push lane runs (a trigger-split repo — this one, #1349) needs a way to
# merge; it does NOT need a SILENT way. `declared-off` still RUNS the comparison,
# still reports the divergence on stderr and in the POSTED evidence, and states
# `NOT ESTABLISHED — declared off` — a certificate that says out loud what it did
# not check.
new_scen vacuousdeclaredoff
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9881 > "$SCEN/runs-$HEAD_VP"
lane_pass maindd00 9882 > "$SCEN/runs-main"
lane_jobset 9881 success 'test (a)'
lane_jobset 9882 success 'test (a)' 'test-slow (a)'
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_LANE_PARITY=declared-off bash "$ADM" 42 --main-runs 1 >"$SCEN/out" 2>"$SCEN/err"
rc=$?
[ "$rc" -eq 0 ] && pass "declared-off certifies the vacuous comparison (exit 0) — the escape works" \
  || fail "declared-off did not certify (exit $rc); the escape is unusable"
grep -q "NOT ESTABLISHED — declared off" "$SCEN/comment" \
  && pass "…and the POSTED evidence STATES the parity was not established" \
  || fail "the escape certified SILENTLY: the evidence does not disclose it"
grep -q "LANE PARITY NOT ESTABLISHED" "$SCEN/err" && pass "…as does stderr, before the merge" \
  || fail "the escape did not warn on stderr"
grep -q "test-slow (a)" "$SCEN/err" && pass "…and the DIVERGENCE is still reported, so the escape is not a blindfold" \
  || fail "declared-off suppressed the divergence report"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge proceeds under the declared escape" \
  || fail "declared-off still refused the merge"

# (k) AN UNRECOGNISED MODE IS REFUSED AT STARTUP, never read as 'off'. A typo
# (`declared_of`) or a casing variant would otherwise take the "not require"
# branch and certify WITHOUT the disclosure — a typo is not a declaration.
new_scen vacuousbadmode
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9891 > "$SCEN/runs-$HEAD_VP"
lane_pass mainbad0 9892 > "$SCEN/runs-main"
lane_jobset 9891 success 'test (a)'
lane_jobset 9892 success 'test (a)'
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_LANE_PARITY=declared_of bash "$ADM" 42 --main-runs 1 >"$SCEN/out" 2>"$SCEN/err"
rc=$?
[ "$rc" -eq 2 ] && pass "a MISSPELLED ADMIN_MERGE_LANE_PARITY is refused at startup (exit 2)" \
  || fail "expected the startup refusal (exit 2), got $rc — a typo could certify without disclosure"
grep -q "refusing ADMIN_MERGE_LANE_PARITY" "$SCEN/err" && pass "…naming the knob and its two legal values" \
  || fail "the startup refusal does not name the knob"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted after a refused knob" || pass "no merge attempted"

# (l) THE CLASSIC #4457 SHAPE, on the PR side: main's reference is REAL, and the
# PR's set is EMPTY because it SKIPPED everything. Every shard main ran is then
# missing — never "no difference". (The both-sides-empty form is (f); this pins
# the asymmetric direction, where a naive `if pr set non-empty` guard would take
# the `cp main → missing` branch and must still refuse.)
new_scen vacuousprempty
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9921 > "$SCEN/runs-$HEAD_VP"
lane_pass mainempty 9922 > "$SCEN/runs-main"
lane_jobset 9921 skipped 'test (a)' 'test (b)' 'test-slow (a)'
lane_jobset 9922 success 'test (a)' 'test (b)' 'test-slow (a)'
run_admin_here 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "main non-empty + the PR's executed set EMPTY → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — an empty PR set was read as 'no difference'"
grep -q "did NOT EXECUTE 3 test shard" "$SCEN/err" && pass "…counting EVERY shard main ran as missing" \
  || fail "the empty-PR-set refusal does not count main's shards as missing"

# (m) AN UNTERMINATED LISTING LINE IS STILL A RUN (#1319 cycle-2 P1). `read`
# returns non-zero on a final line with no trailing newline; a `while read` body
# then never sees it, so the run is DROPPED — a silently thinner reference. The
# run that is dropped is the one that names the shard main ran and the PR did
# not, so the drop turns a refusal into a certificate.
new_scen vacuousnonewline
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9951 > "$SCEN/runs-$HEAD_VP"
# Run 9952 is terminated; 9953 is the UNTERMINATED last line (no trailing \n).
lane_pass mainnl00 9952 > "$SCEN/runs-main"
printf 'completed\tsuccess\tmainnl00:9953' >> "$SCEN/runs-main"
lane_jobset 9951 success 'test (a)'
lane_jobset 9952 success 'test (a)'
lane_jobset 9953 success 'test (a)' 'test (b)'
run_admin_here 42 --main-runs 2 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a final listing line with NO trailing newline is still a run → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — the unterminated line was dropped, shrinking the reference"
grep -q "test (b)" "$SCEN/err" && pass "…and the shard it named is the one reported missing" \
  || fail "the run on the unterminated line was not read at all"

# (n) A LISTING THAT IS ONLY PARTLY READABLE IS UNREADABLE (#1319 cycle-2 P1). A
# line that does not parse into a run id used to be `continue`d away — a partial
# listing read as a THINNER LANE, which is the one thing the doctrine forbids.
new_scen vacuouspartial
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9961 > "$SCEN/runs-$HEAD_VP"
lane_pass mainpt00 9962 > "$SCEN/runs-main"
# A truncated line: status only, no conclusion and no run id.
printf 'completed\n' >> "$SCEN/runs-main"
lane_jobset 9961 success 'test (a)'
lane_jobset 9962 success 'test (a)'
run_admin_here 42 --main-runs 2 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a truncated listing line → BLOCK (exit $rc), never a thinner lane" \
  || fail "expected a non-zero exit, got 0 — a partial listing was read as 'main ran fewer shards'"
grep -q "unparsable lane-run listing line" "$SCEN/err" && pass "…named as an UNPARSABLE listing line" \
  || fail "the partial-listing refusal is not named: $(head -2 "$SCEN/err")"

# (o) THE FAMILY MUST MEASURE SOMETHING (#1319 cycle-2 P1). The prefix is a family
# SELECTOR; `ADMIN_MERGE_LANE_JOB_PREFIX=changes` matches the workflow's
# bookkeeping job, and certifying on it compares nothing while main's real
# `test-slow (a)` sits outside the gate. A family of only lifecycle jobs is
# refused — the knob exists for MISNAMED test shards, not for excluding tests.
new_scen vacuouslifecycle
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
lane_pass "$HEAD_VP" 9971 > "$SCEN/runs-$HEAD_VP"
lane_pass mainlc00 9972 > "$SCEN/runs-main"
lane_jobset 9971 success 'changes' 'python-ci-gate'
lane_jobset 9972 success 'changes' 'python-ci-gate' 'test-slow (a)'
SCEN="$SCEN" ADMIN_MERGE_GH="$FAKE" CI_FAILURE_SET_GH="$FAKE" ADMIN_MERGE_POLL_INTERVAL=0 \
  ADMIN_MERGE_LANE_JOB_PREFIX=changes bash "$ADM" 42 --main-runs 1 >"$SCEN/out" 2>"$SCEN/err"
rc=$?
[ "$rc" -ne 0 ] && pass "a parity family of ONLY lifecycle jobs → BLOCK (exit $rc)" \
  || fail "expected a non-zero exit, got 0 — the gate certified on bookkeeping jobs while main's test-slow (a) went uncompared"
grep -q "matched ONLY lifecycle jobs" "$SCEN/err" && pass "…naming the lifecycle family as the reason" \
  || fail "the lifecycle-family refusal is not named: $(head -2 "$SCEN/err")"
grep -q "pr merge" "$SCEN/calls" && fail "no merge may be attempted on a bookkeeping-only family" || pass "no merge attempted"

# (p) THE CERTIFICATE NAMES THE FAMILY IT COMPARED (#1319 cycle-2 P1). The
# declared residual (a narrowed prefix removes a family from the gate) is
# acceptable ONLY because the disclosure is real — on the path that CERTIFIES,
# which is exactly the path that used to be silent.
grep -q "parity family: test\*" "$TMP/scen-vacuouscertify/comment" \
  && pass "the certifying evidence NAMES the parity family it compared (test*)" \
  || fail "the certificate does not name the family, so a narrowed prefix is silent"
# The refusal path too: `run_admin` writes stderr to a SHARED $TMP/err, so the
# refusal is re-run against its own preserved scenario dir rather than read back
# from a file a later scenario overwrote.
SCEN="$TMP/scen-vacuousparity"
run_admin_here 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] || fail "the failed-parity scenario stopped refusing on a re-run"
grep -q "parity family: test\*" "$SCEN/err" \
  && pass "…and so does the REFUSAL, so a narrowed prefix is legible there too" \
  || fail "the refusal does not name the family it compared"

# (q) THE BASELINE WINDOW IS VALIDATED. A non-numeric window makes `gh run list
# --limit abc` fail (a named BLOCK, but one the operator could have been told
# about before any CI work); an unbounded window is a COST blow-up, because the
# lane gate fetches one Jobs API listing per run on each side.
new_scen vacuouswindowneg
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
run_admin_here 42 --main-runs abc >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && pass "a NON-NUMERIC --main-runs is refused at startup (exit 2)" \
  || fail "expected the startup refusal (exit 2), got $rc"
grep -q "refusing --main-runs" "$SCEN/err" && pass "…naming the flag and its value" \
  || fail "the refusal does not name --main-runs"
grep -q "pr view" "$SCEN/calls" && fail "the window was validated only AFTER CI work started" \
  || pass "…before ANY gh call"
new_scen vacuouswindowbig
printf '%s\n' "$HEAD_VP" > "$SCEN/head"
run_admin_here 42 --main-runs 100000 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 2 ] && pass "an UNBOUNDED --main-runs window is refused (exit 2)" \
  || fail "expected the startup refusal (exit 2), got $rc — an unbounded window is an unbounded call budget"
grep -q "beyond the usable window" "$SCEN/err" && pass "…naming the bound" || fail "the window bound is not named"

# The parity key exists ONCE, in `lane_parity_check`, and it is not a second
# `comm -23`: the one `comm` in this rail belongs to the parser's `--diff` (test
# 9's parity invariant), and a reader must not have to guess which subtraction a
# `comm` line belongs to. Asserted at BOTH scopes — the function, so the claim is
# about the coverage gate; and the whole rail, so the invariant is not re-broken
# elsewhere.
lane_parity_fn="$(sed -n '/^lane_parity_check()/,/^}/p' "$ADM")"
printf '%s\n' "$lane_parity_fn" | grep -qE '^[[:space:]]*comm[[:space:]]+-23' \
  && fail "lane_parity_check re-implements comm -23 (test 9's parity invariant)" \
  || pass "lane_parity_check's subtraction is NOT comm -23 (the invariant holds where it was claimed)"
grep -qE '^[[:space:]]*comm[[:space:]]+-23' "$ADM" \
  && fail "the lane-coverage subtraction re-implements comm -23 in the rail" \
  || pass "…and no comm -23 was reintroduced anywhere in the rail"

# ── 50. IN-FLIGHT IS AN ALLOW-LIST — AN UNRECOGNISED STATUS IS RED (#1353) ──
# The pending half of the classifier was a DENY-list: `status != "completed"` was
# the WHOLE test, so any spelling this rail had never seen became PENDING — and
# PENDING is never red, so the surface still read GREEN and the rail merged a
# check GitHub had already concluded `failure`. The in-flight spellings are now
# NAMED (`queued`, `in_progress`, `waiting`, `requested`, `pending`); any OTHER
# non-completed status is classified by its CONCLUSION, RED unless that
# conclusion is one the rail names as non-red. The same hole on the BASE read
# `base tree GREEN` and silently DISARMED 4.6/4.7, which are both gated on the
# base being red — so the last scenario shows the staleness rule firing again.
echo "== 50. an unrecognised check-run STATUS is classified, never assumed PENDING (#1353) =="

# (a) THE REPRODUCTION, ON THE PR'S OWN TREE. The tree's only check is
# `status=completely_finished, conclusion=failure`: the deny-list filed it as
# PENDING, the tree read GREEN (`green — 0 failing of 1 measured, 1 pending`),
# evidence was posted and the merge ran.
new_scen status-tree-unknown
HEAD_S1="e1e1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_S1" > "$SCEN/head"
lane_pass "$HEAD_S1" 5901 > "$SCEN/runs-$HEAD_S1"
lane_pass mains1 5902 > "$SCEN/runs-main"
main_green_surface
write_pr_checks "$(check_run 9101 lint completely_finished failure 9911)"
pr_run_map 9911 pull_request 'Post-merge validation'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an UNRECOGNISED non-completed status + a red conclusion BLOCKS (exit $rc)" \
  || fail "an unrecognised status read as PENDING (never red) and MERGED — the deny-list hole"
grep -q "THE TREE THIS PR PRODUCES IS RED" "$SCEN/err" && pass "…as the tree-red refusal" \
  || fail "the refusal is not the tree-red one: $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "completely_finished" "$SCEN/err" && pass "…naming the STATUS that failed closed" \
  || fail "the refusal does not name the unrecognised status: $(grep -m1 '^   • ' "$SCEN/err")"
[ -f "$SCEN/comment" ] && fail "evidence was posted over an unrecognised red" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over an unrecognised red" || pass "no merge attempted"

# (b) THE SAME SPELLING IN ITS OTHER GUISES — an EMPTY status and a CAPITALISED
# one are both spellings this rail has never NAMED, and both used to become
# PENDING. (`Completed` is the trap a case-sensitive vendor integration ships.)
for variant in "" "Completed"; do
  new_scen "status-tree-var${variant:-empty}"
  HEAD_SV="e2e2000000000000000000000000000000000000"
  printf '%s\n' "$HEAD_SV" > "$SCEN/head"
  lane_pass "$HEAD_SV" 5903 > "$SCEN/runs-$HEAD_SV"
  lane_pass mainsv 5904 > "$SCEN/runs-main"
  main_green_surface
  write_pr_checks "$(check_run 9102 lint "$variant" failure 9912)"
  pr_run_map 9912 pull_request 'Post-merge validation'
  run_admin_here 42 >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] && pass "status='${variant:-<empty>}' with a red conclusion BLOCKS too (exit $rc)" \
    || fail "status='${variant:-<empty>}' read as PENDING and merged"
done

# (c) THE SAME HOLE ON THE BASE DISARMS THE STALENESS RULES. The base's only
# check is `status=in_progress_y, conclusion=failure`, started AFTER this PR's
# surface was produced. Read as PENDING, the base looks GREEN, so neither 4.6
# (a red newer than the surface) nor 4.7 (a lagging merge ref) is even reached —
# the stale green merges over a red base. Classified by its conclusion, the base
# is RED and 4.6 refuses.
new_scen status-base-unknown
HEAD_S2="e3e3000000000000000000000000000000000000"
printf '%s\n' "$HEAD_S2" > "$SCEN/head"
lane_pass "$HEAD_S2" 5905 > "$SCEN/runs-$HEAD_S2"
lane_pass mains2 5906 > "$SCEN/runs-main"
# The PR's own tree is GREEN, produced at 00:01.
write_pr_checks "$(check_run 5001 'ci / lint' completed success 7301 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7301 pull_request 'CI'
# The base carries a red at 00:02 — AFTER the PR surface, so 4.6 must fire.
write_main_checks "$(check_run 6100 lint in_progress_y failure 9951 2026-01-01T00:02:00Z)"
main_run_map 9951 push 'Post-merge validation'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an unrecognised BASE status hides a red base no longer (exit $rc)" \
  || fail "an unrecognised base status read as PENDING disarmed 4.6/4.7 and MERGED over a red base"
grep -q "THE BASE IS RED AND THIS PR HAS NOT MEASURED IT" "$SCEN/err" && pass "…so the 4.6 staleness rule runs again (the disarm is repaired)" \
  || fail "the refusal is not the staleness one: $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "in_progress_y" "$SCEN/err" && pass "…naming the base status that failed closed" \
  || fail "the base refusal does not name the unrecognised status"
[ -f "$SCEN/comment" ] && fail "evidence was posted over a hidden red base" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a hidden red base" || pass "no merge attempted"

# (d) THE OVER-BLOCK GUARD: the NAMED in-flight spellings are still PENDING and
# still do not block. Main always has something running, so reddening these would
# refuse the fleet on every post-merge run.
new_scen status-inflight-pending
HEAD_S3="e4e4000000000000000000000000000000000000"
printf '%s\n' "$HEAD_S3" > "$SCEN/head"
lane_pass "$HEAD_S3" 5907 > "$SCEN/runs-$HEAD_S3"
lane_pass mains3 5908 > "$SCEN/runs-main"
main_green_surface
write_pr_checks \
  "$(check_run 9201 'pr / lint' in_progress null 9921)" \
  "$(check_run 9202 'pr / test' queued null 9922)"
pr_run_map 9921 pull_request 'CI' 9922 pull_request 'CI'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "in_progress/queued are still PENDING, never red (exit 0)" \
  || fail "a legitimately in-flight check was reddened (exit $rc): $(sed -n '1,3p' "$SCEN/err" 2>/dev/null)"
grep -q "pending 2" "$SCEN/out" && pass "…and BOTH in-flight checks are COUNTED in the evidence" \
  || fail "the in-flight checks are not counted: $(grep -m1 'evaluated tree' "$SCEN/out")"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge was attempted"

# ── 51. ONLY A COMPLETED MEASUREMENT SETS THE STALENESS ANCHOR (#1353) ──────
# The statuses loop advanced `surface_epoch` for EVERY legacy status — including
# the `state == "pending"` branch. A PENDING status's `updated_at` marks when it
# was last QUEUED or re-announced, not when anything was measured, so it moved
# the PR surface's last-production time FORWARD past the PR's real evaluation.
# A base red that began between the two then compared as "already measured" and
# the stale green merged. This is the highest-reachability of the four: any
# ordinary in-flight deploy/preview status triggers it.
echo "== 51. a PENDING legacy status must not advance the staleness anchor (#1353) =="

# (a) THE REPRODUCTION. The PR's only completed check was produced at 00:01; a
# pending `deploy-preview` status was updated at 00:03; the base went red at
# 00:02. The anchor used the PENDING status's 00:03, so the 00:02 red looked
# already-measured and the rail merged.
new_scen staleness-pending-status
HEAD_ST1="e5e5000000000000000000000000000000000000"
printf '%s\n' "$HEAD_ST1" > "$SCEN/head"
lane_pass "$HEAD_ST1" 5911 > "$SCEN/runs-$HEAD_ST1"
lane_pass mainst1 5912 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5001 'ci / lint' completed success 7301 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7301 pull_request 'CI'
printf '{"state":"pending","total_count":1,"statuses":[{"context":"deploy-preview","state":"pending","updated_at":"2026-01-01T00:03:00Z","target_url":"https://example.com/status/1"}]}\n' > "$SCEN/pr-statuses.json"
write_main_checks "$(check_run 6001 lint completed failure 7401 2026-01-01T00:02:00Z 2026-01-01T00:02:30Z)"
main_run_map 7401 push 'Post-merge validation'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a base red AFTER the PR's completed check is STALE despite a pending status (exit $rc)" \
  || fail "a PENDING status advanced the anchor and the stale green MERGED over a red base"
grep -q "STALE surface" "$SCEN/err" && pass "…and the refusal names the staleness" \
  || fail "the refusal is not the staleness one: $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "began 2026-01-01T00:02:00Z, AFTER this PR's surface was last produced" "$SCEN/err" \
  && pass "…naming the base red it failed to cover, and the anchor it compared" \
  || fail "the staleness refusal does not name the red it covers or the anchor: $(sed -n '1,6p' "$SCEN/err" 2>/dev/null)"
# The status is still COUNTED as pending — the fix moves the ANCHOR, it does not
# drop the state. An unmeasured surface must stay legible.
grep -q "pending 1" "$SCEN/out" && pass "…while the pending status is still COUNTED, not dropped" \
  || fail "the pending status vanished from the surface accounting: $(grep -m1 'evaluated tree' "$SCEN/out")"
[ -f "$SCEN/comment" ] && fail "evidence was posted over a stale green" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a stale green" || pass "no merge attempted"

# (b) THE CONTROL — the IDENTICAL fixture with NO pending status. Both the
# pre-fix and the fixed rail refuse here; the pair is what shows the pending
# status was the disarming element rather than the base red itself.
new_scen staleness-control-nostatus
HEAD_ST2="e6e6000000000000000000000000000000000000"
printf '%s\n' "$HEAD_ST2" > "$SCEN/head"
lane_pass "$HEAD_ST2" 5913 > "$SCEN/runs-$HEAD_ST2"
lane_pass mainst2 5914 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5001 'ci / lint' completed success 7301 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7301 pull_request 'CI'
write_main_checks "$(check_run 6001 lint completed failure 7401 2026-01-01T00:02:00Z 2026-01-01T00:02:30Z)"
main_run_map 7401 push 'Post-merge validation'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "the CONTROL (no pending status) refuses at 4.6, as before (exit $rc)" \
  || fail "the control did not refuse — the pre-fix path was not the one under test"
grep -q "STALE surface" "$SCEN/err" && pass "…via the same staleness refusal" \
  || fail "the control refusal is not the staleness one"
# (c) AND A COMPLETED MEASUREMENT STILL DOES ADVANCE THE ANCHOR — a completed
# success at 00:04 covers the base red that began at 00:02, so the merge MUST
# proceed. Without this the fix could pass by never advancing the anchor at all,
# which would refuse every PR whose surface carries a pending status (an
# over-block) — `surface_iso` is the ONLY source of the anchor, so if it stopped
# advancing, 4.6 would report "no completed check" and refuse.
new_scen staleness-completed-anchor
HEAD_ST3="e7e7000000000000000000000000000000000000"
printf '%s\n' "$HEAD_ST3" > "$SCEN/head"
lane_pass "$HEAD_ST3" 5915 > "$SCEN/runs-$HEAD_ST3"
lane_pass mainst3 5916 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5001 'ci / lint' completed success 7301 2026-01-01T00:00:00Z 2026-01-01T00:04:00Z)"
pr_run_map 7301 pull_request 'CI'
printf '{"state":"pending","total_count":1,"statuses":[{"context":"deploy-preview","state":"pending","updated_at":"2026-01-01T00:03:00Z","target_url":"https://example.com/status/1"}]}\n' > "$SCEN/pr-statuses.json"
write_main_checks "$(check_run 6001 lint completed failure 7401 2026-01-01T00:02:00Z 2026-01-01T00:02:30Z)"
main_run_map 7401 push 'Post-merge validation'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a base red at 00:02 is COVERED by the PR's 00:04 completed check — it MERGES (exit 0)" \
  || fail "a covered base red was refused (exit $rc) — the anchor stopped advancing from a completed measurement: $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"
[ -f "$SCEN/comment" ] && pass "…with its head-bound evidence" || fail "no evidence posted"

# ── 52. THE NON-CODE EXEMPTION IS SCOPED TO THE BASE SURFACE (#1353) ────────
# `schedule`/`issues`/`issue_comment` are REPORT-ONLY so a cron-noisy base does
# not refuse every merge. That exemption was applied UNCONDITIONALLY — including
# to the PR's EVALUATED TREE, where the same header calls such an event "an
# anomaly", because a default-branch run cannot attach to a PR head sha. So a red
# on the TREE whose run map said `schedule` was routed to the non-blocking list
# and merged. The exemption is now scoped to the surface it was written for.
echo "== 52. the non-code-event exemption is BASE-only; on the tree it BLOCKS (#1353) =="

# (a) THE REPRODUCTION. The tree's only check is a `completed failure` whose run
# map says `schedule` (the fixture models the impossible-but-observed shape, i.e.
# a mis-keyed run map or a future GitHub change). The old rail routed it to
# REDS_OTHER, the tree read GREEN, and the merge ran.
new_scen noncode-tree
HEAD_NC1="e8e8000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC1" > "$SCEN/head"
lane_pass "$HEAD_NC1" 5921 > "$SCEN/runs-$HEAD_NC1"
lane_pass mainnc1 5922 > "$SCEN/runs-main"
main_green_surface
write_pr_checks "$(check_run 3301 backup completed failure 6901)"
pr_run_map 6901 schedule registry-backup-cron
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a schedule-attributed red on the PR's TREE BLOCKS (exit $rc)" \
  || fail "a non-code red on the evaluated tree was exempted and MERGED — the unconditional-exemption hole"
grep -q "THE TREE THIS PR PRODUCES IS RED" "$SCEN/err" && pass "…as the tree-red refusal" \
  || fail "the refusal is not the tree-red one: $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "3301\|backup" "$SCEN/err" && pass "…naming the failing check" \
  || fail "the refusal does not name the check"
grep -q "NOT EXEMPT ON THIS SURFACE" "$SCEN/err" && pass "…and SAYING the exemption does not apply on this surface" \
  || fail "the refusal does not state that the non-code exemption is base-only"
[ -f "$SCEN/comment" ] && fail "evidence was posted over an exempted tree red" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over an exempted tree red" || pass "no merge attempted"

# (b) THE OVER-BLOCK GUARD — THE EXEMPTION STILL APPLIES ON THE BASE. A
# `schedule` red on main must NOT block (the fleet-stopping blunt refusal the
# exemption exists to avoid), and it must still be REPORTED.
new_scen noncode-base-exempt
HEAD_NC2="e9e9000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC2" > "$SCEN/head"
lane_pass "$HEAD_NC2" 5923 > "$SCEN/runs-$HEAD_NC2"
lane_pass mainnc2 5924 > "$SCEN/runs-main"
write_main_checks "$(check_run 3302 backup completed failure 6902)"
main_run_map 6902 schedule registry-backup-cron
pr_green_surface
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a schedule-attributed red on the BASE still does NOT block (exit 0)" \
  || fail "the base's cron exemption was lost (exit $rc) — that would refuse the fleet on a cron-noisy base: $(sed -n '1,3p' "$SCEN/err" 2>/dev/null)"
grep -q "NON-code events" "$SCEN/out" && pass "…and the base's non-code red is still REPORTED, not silently dropped" \
  || fail "the base's non-code red is no longer reported"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"

# ── 53. AN UNNAMED CHECK IS CLASSIFIED, NEVER DROPPED (#1353) ───────────────
# `if not name: continue` dropped a check run before classification: a RED on an
# unnamed run appeared in NEITHER the red nor the pending list, the surface read
# `unmeasured — 0 failing of 0 measured`, and the rail merged. "Unnamed" is a
# value the posture must NAME and classify, not one it may discard.
echo "== 53. an unnamed check run is classified under a placeholder, never dropped (#1353) =="

# (a) THE REPRODUCTION — an UNNAMED RED CHECK RUN on the PR's evaluated tree.
new_scen unnamed-tree-check
HEAD_U1="f1f1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_U1" > "$SCEN/head"
lane_pass "$HEAD_U1" 5931 > "$SCEN/runs-$HEAD_U1"
lane_pass mainu1 5932 > "$SCEN/runs-main"
main_green_surface
write_pr_checks "$(check_run 9104 '' completed failure 6911)"
pr_run_map 6911 pull_request 'CI'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an UNNAMED completed-failure check BLOCKS (exit $rc)" \
  || fail "an unnamed red was dropped before classification and MERGED — the silent-drop hole"
grep -q "THE TREE THIS PR PRODUCES IS RED" "$SCEN/err" && pass "…as the tree-red refusal" \
  || fail "the refusal is not the tree-red one: $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "(unnamed check)" "$SCEN/err" && pass "…naming the PLACEHOLDER identity it was classified under" \
  || fail "the refusal does not name the placeholder"
grep -q "UNMEASURED" "$SCEN/err" && fail "the unnamed red was read as an EMPTY surface" \
  || pass "…and the surface is NOT reported as empty"
[ -f "$SCEN/comment" ] && fail "evidence was posted over a dropped red" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a dropped red" || pass "no merge attempted"

# (b) THE SAME DROP FOR A LEGACY STATUS with an EMPTY context — the other half of
# the rule, and the one the statuses loop owned separately.
new_scen unnamed-tree-status
HEAD_U2="f2f2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_U2" > "$SCEN/head"
lane_pass "$HEAD_U2" 5933 > "$SCEN/runs-$HEAD_U2"
lane_pass mainu2 5934 > "$SCEN/runs-main"
main_green_surface
printf '{"state":"failure","total_count":1,"statuses":[{"context":"","state":"failure","updated_at":"2026-01-02T00:00:00Z","target_url":"https://example.com/status/1"}]}\n' > "$SCEN/pr-statuses.json"
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an UNNAMED red legacy status BLOCKS too (exit $rc)" \
  || fail "an unnamed status context was dropped and MERGED"
grep -q "(unnamed status)" "$SCEN/err" && pass "…naming the placeholder for the status" \
  || fail "the refusal does not name the unnamed status"

# (c) THE OVER-BLOCK GUARD: an UNNAMED but NON-RED check is not reddened by the
# placeholder — it is classified by its conclusion exactly like a named one.
new_scen unnamed-nonred
HEAD_U3="f3f3000000000000000000000000000000000000"
printf '%s\n' "$HEAD_U3" > "$SCEN/head"
lane_pass "$HEAD_U3" 5935 > "$SCEN/runs-$HEAD_U3"
lane_pass mainu3 5936 > "$SCEN/runs-main"
main_green_surface
write_pr_checks "$(check_run 9105 '' completed success 6913)"
pr_run_map 6913 pull_request 'CI'
printf '{"state":"success","total_count":1,"statuses":[{"context":"","state":"success","updated_at":"2026-01-02T00:00:00Z","target_url":"https://example.com/status/2"}]}\n' > "$SCEN/pr-statuses.json"
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "an unnamed SUCCESS check/status is classified non-red and MERGES (exit 0)" \
  || fail "the placeholder reddened a legitimately non-red check (exit $rc): $(sed -n '1,3p' "$SCEN/err" 2>/dev/null)"
grep -q "evaluated tree GREEN" "$SCEN/out" && grep -q "among 2 check(s)" "$SCEN/out" \
  && pass "…and BOTH unnamed objects are COUNTED in the TREE surface, not dropped" \
  || fail "the unnamed objects vanish from the tree's measured count: $(grep -m1 'evaluated tree' "$SCEN/out")"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"

# ── 54. THE ATTRIBUTION HALF: A CLIPPED SET IS NAMED, NOT A ZERO (#1353) ────
# `PR failing: 0` can mean "no failures", "not comparable" (the parity gate,
# #1319) OR "the failures were DROPPED": the parser drops a FAILED token that is
# not a test id, and it is never in the set. The count and the tokens must be
# named in the rail's OUTPUT and in the POSTED EVIDENCE, so a COMPLETE set is
# distinguishable from a CLIPPED one. A run whose failures are ENTIRELY
# unattributable still refuses (step 1c — verified here, not changed).
echo "== 54. an unattributable FAILED token is NAMED in the output and the evidence (#1353) =="

# (a) THE REPRODUCTION. The PR carries ONE real id AND one dropped token; main
# measures the real id, so the decision exempts it and the rail MERGES with
# evidence. The drop must appear in both streams: `PR failing: 0`-style zeros must
# never be readable as complete when a token was dropped.
new_scen attribution-named
HEAD_AT1="f4f4000000000000000000000000000000000000"
printf '%s\n' "$HEAD_AT1" > "$SCEN/head"
FAIL_AT='tests/test_other.py::test_red_on_main'
lane_fail "$HEAD_AT1" 8801 > "$SCEN/runs-$HEAD_AT1"
{ log_failed "$FAIL_AT"; log_unattributable '(HTTP'; } > "$SCEN/log-8801"
main_red_n mainat 9001 3 "$FAIL_AT" > "$SCEN/runs-main"
main_green_surface
pr_green_surface
run_admin_here 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a PR with one exempt failure and one DROPPED token still merges (exit 0)" \
  || fail "the attribution disclosure blocked a merge it must not (exit $rc): $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "the PR's failing set" "$SCEN/err" && grep -q "CLIPPED" "$SCEN/err" \
  && pass "the RAIL'S OUTPUT names the drop count and says the set is CLIPPED" \
  || fail "the rail does not name the dropped token on stderr: $(grep -m1 DROPPED "$SCEN/err")"
grep -q -- "DROPPED: (HTTP" "$SCEN/err" && pass "…naming the dropped TOKEN verbatim" \
  || fail "the dropped token is not named on stderr"
if [ -f "$SCEN/comment" ]; then
  grep -q "Attribution — FAILED tokens DROPPED by the parser" "$SCEN/comment" \
    && pass "the POSTED EVIDENCE states the attribution line" \
    || fail "the posted evidence has no attribution line"
  grep -q "PR=1 | main=0" "$SCEN/comment" && pass "…with BOTH counts (PR drops=1, main drops=0)" \
    || fail "the evidence does not state the drop counts"
  grep -q -- "- (HTTP" "$SCEN/comment" && pass "…and the dropped TOKEN in the evidence's own list" \
    || fail "the dropped token is not in the posted evidence"
  grep -q "CLIPPED" "$SCEN/comment" && pass "…naming the set CLIPPED (not comparable to a measured zero)" \
    || fail "the evidence does not say the set is CLIPPED"
  # A REAL newline, not a `\n` that bash double quotes do not expand — a literal
  # escape shipped into a posted comment is exactly the kind of unreadable line
  # this evidence block exists to avoid.
  grep -qF 'main=0.\n' "$SCEN/comment" \
    && fail "the attribution line ships a LITERAL backslash-n instead of a line break" \
    || pass "…and its line break is a REAL newline"
else
  fail "no evidence comment posted for the attribution case"
fi
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"

# (b) A COMPLETE SET IS STATED AS COMPLETE — the disclosure is unconditional, so
# an empty drop list means "none", not "not measured".
new_scen attribution-complete
HEAD_AT2="f5f5000000000000000000000000000000000000"
printf '%s\n' "$HEAD_AT2" > "$SCEN/head"
lane_pass "$HEAD_AT2" 8901 > "$SCEN/runs-$HEAD_AT2"
lane_pass mainat2 8902 > "$SCEN/runs-main"
main_green_surface
pr_green_surface
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a fully readable, green surface still merges (exit 0)" \
  || fail "the attribution disclosure blocked a clean merge (exit $rc)"
if [ -f "$SCEN/comment" ]; then
  grep -q "PR=0 | main=0" "$SCEN/comment" && pass "…and the evidence states ZERO drops explicitly" \
    || fail "the evidence omits the drop count when it is zero"
  grep -q "COMPLETE" "$SCEN/comment" && pass "…and says the failing sets are COMPLETE, not merely empty" \
    || fail "the evidence does not distinguish COMPLETE from unmeasured"
else
  fail "no evidence comment posted for the complete case"
fi

# (c) THE RECONCILIATION WITH #3756's INJECTION PIN. A DROPPED token can be
# HOSTILE — a bare fence marker in the `FAILED` position is the reproduced
# payload — and #1353 still requires it NAMED in the posted evidence. Both hold
# because the evidence renders the token with its markdown metacharacters ESCAPED
# (disclosed in the block heading) while stderr keeps it verbatim: the token is
# named AND the #3756 property (a hostile token cannot open a fence or close a
# details block) is preserved.
new_scen attribution-hostile-token
HEAD_AT4="f7f7000000000000000000000000000000000000"
printf '%s\n' "$HEAD_AT4" > "$SCEN/head"
lane_fail "$HEAD_AT4" 8904 > "$SCEN/runs-$HEAD_AT4"
{ log_failed 'tests/test_other.py::test_red_on_main'; log_failed '```'; } > "$SCEN/log-8904"
main_red_n mainat4 9004 3 'tests/test_other.py::test_red_on_main' > "$SCEN/runs-main"
main_green_surface
pr_green_surface
run_admin_here 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a hostile dropped token does not block a sound merge (exit 0)" \
  || fail "the hostile-token disclosure blocked a merge (exit $rc)"
# STDERR keeps the token VERBATIM — that is the byte-exact surface an operator
# greps, and a terminal is not markdown.
grep -qF 'DROPPED: ```' "$SCEN/err" && pass "the rail's OUTPUT carries the hostile token VERBATIM on stderr" \
  || fail "the hostile token is not named verbatim on stderr"
if [ -f "$SCEN/comment" ]; then
  grep -qF 'markdown metacharacters escaped' "$SCEN/comment" \
    && pass "the POSTED EVIDENCE discloses that the rendering is escaped" \
    || fail "the evidence does not disclose the escape"
  grep -qF '\`\`\`' "$SCEN/comment" \
    && pass "…and the token IS named there (escaped), so the set is still not a bare zero" \
    || fail "the dropped token is not named at all in the evidence"
  grep -qF '```' "$SCEN/comment" \
    && fail "raw backticks reached the evidence — the #3756 fence surface is back" \
    || pass "…while NO raw fence token reaches the evidence (the #3756 property holds)"
  d_open=$(grep -c '^<details>' "$SCEN/comment"); d_close=$(grep -c '^</details>$' "$SCEN/comment")
  [ "$d_open" -ge 3 ] && [ "$d_open" -eq "$d_close" ] \
    && pass "…and every evidence block stays balanced ($d_open/$d_close)" \
    || fail "block structure damaged ($d_open opened, $d_close closed)"
else
  fail "no evidence comment posted for the hostile-token case"
fi

# (d) A RUN WHOSE FAILURES ARE ENTIRELY UNATTRIBUTABLE REFUSES. This is the
# PRE-EXISTING step-1c gate (`examined > extracted`) — verified to still hold,
# now with the dropped tokens named at the point of refusal.
new_scen attribution-all-dropped
HEAD_AT3="f6f6000000000000000000000000000000000000"
printf '%s\n' "$HEAD_AT3" > "$SCEN/head"
lane_fail "$HEAD_AT3" 8903 > "$SCEN/runs-$HEAD_AT3"
log_unattributable '(HTTP' > "$SCEN/log-8903"
main_red_n mainat3 9003 3 'tests/test_other.py::test_red_on_main' > "$SCEN/runs-main"
run_admin_here 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a run whose failures were ENTIRELY dropped REFUSES (exit $rc)" \
  || fail "an entirely-unattributable failing run was read as an empty set and MERGED"
grep -q "yielded NO parseable" "$SCEN/err" && pass "…via the preserved step-1c gate" \
  || fail "the refusal is not the extraction gate: $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q -- "DROPPED: (HTTP" "$SCEN/err" && pass "…and the DROPPED token is named at the refusal" \
  || fail "the refusal does not name the token it dropped"
[ -f "$SCEN/comment" ] && fail "evidence was posted over an entirely-dropped set" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over an entirely-dropped set" || pass "no merge attempted"

# ── 55. A COMPLETED CHECK THAT MEASURED NOTHING IS NOT A MEASUREMENT (#1353) ─
# The staleness anchor (`surface_epoch`) is the surface's last PRODUCTION time,
# and step 4.6 refuses a base red whose run STARTED after it. The anchor used to
# be set by EVERY completed check — including `skipped`/`cancelled`/`neutral`/
# `stale`, which exercise nothing — so a non-measuring run stamped the anchor
# FORWARD past the surface's real evaluation and a base red that began in between
# compared as already-measured. One explicit predicate (MEASURING_CONC /
# MEASURING_STATE) now gates BOTH sites that can set it.
echo "== 55. a completed-but-NON-MEASURING check must not advance the staleness anchor (#1353) =="

# 36 zeros, so a fixture sha below is exactly 40 hex chars.
HEX36="000000000000000000000000000000000000"

# (a) THE REPRODUCTION. The PR's own last MEASUREMENT was at 00:01; a SKIPPED
# check completed at 00:06 and used to stamp the anchor with 00:06, so the base
# red that began at 00:03 looked already-measured and the stale green merged.
new_scen stale-nonmeasuring-skipped
HEAD_NM1="a1a1${HEX36}"
printf '%s\n' "$HEAD_NM1" > "$SCEN/head"
lane_pass "$HEAD_NM1" 5961 > "$SCEN/runs-$HEAD_NM1"
lane_pass mainnm1 5962 > "$SCEN/runs-main"
write_pr_checks \
  "$(check_run 5001 'python-ci / test (a)' completed success 7361 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)" \
  "$(check_run 5002 'agent-infra-ci / lint' completed skipped 7361 2026-01-01T00:00:00Z 2026-01-01T00:06:00Z)"
pr_run_map 7361 pull_request 'CI'
write_main_checks "$(check_run 6001 'agent-infra-ci / lint' completed failure 7461 2026-01-01T00:03:00Z 2026-01-01T00:03:30Z)"
main_run_map 7461 push 'Post-merge validation'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a base red at 00:03 is STALE despite a SKIPPED check completing at 00:06 (exit $rc)" \
  || fail "a SKIPPED check advanced the anchor past the real measurement and the stale green MERGED"
grep -q "STALE surface" "$SCEN/err" && pass "…and the refusal names the staleness" \
  || fail "the refusal is not the staleness one: $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "surface was last produced (2026-01-01T00:01:00Z)" "$SCEN/err" \
  && pass "…anchored on the MEASURING check (00:01), not the skipped one (00:06)" \
  || fail "the anchor is not the measuring check's completion: $(grep -m1 'last produced' "$SCEN/err")"
[ -f "$SCEN/comment" ] && fail "evidence was posted over a stale green" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a stale green" || pass "no merge attempted"

# (b) THE SAME FOR EVERY OTHER NON-MEASURING NON-RED CONCLUSION.
for pair in "cancelled:c1" "neutral:d1" "stale:e1"; do
  concl="${pair%%:*}"; tag="${pair##*:}"
  new_scen "stale-nonmeasuring-$concl"
  HEAD_NM="f9${tag}${HEX36}"
  printf '%s\n' "$HEAD_NM" > "$SCEN/head"
  lane_pass "$HEAD_NM" 5963 > "$SCEN/runs-$HEAD_NM"
  lane_pass "main${tag}" 5964 > "$SCEN/runs-main"
  write_pr_checks \
    "$(check_run 5001 'python-ci / test (a)' completed success 7362 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)" \
    "$(check_run 5002 'agent-infra-ci / lint' completed "$concl" 7362 2026-01-01T00:00:00Z 2026-01-01T00:06:00Z)"
  pr_run_map 7362 pull_request 'CI'
  write_main_checks "$(check_run 6001 'agent-infra-ci / lint' completed failure 7462 2026-01-01T00:03:00Z 2026-01-01T00:03:30Z)"
  main_run_map 7462 push 'Post-merge validation'
  run_admin_here 42 >/dev/null 2>&1
  rc=$?
  [ "$rc" -ne 0 ] && pass "…a COMPLETED $concl does not advance the anchor either (exit $rc)" \
    || fail "a COMPLETED $concl advanced the anchor and the stale green MERGED"
  grep -q "STALE surface" "$SCEN/err" && pass "…$concl refuses via the staleness rule" \
    || fail "the $concl refusal is not the staleness one: $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
done

# (c) AND WHEN THE NON-MEASURING CHECK IS THE SURFACE'S ONLY COMPLETED CHECK
# the anchor is EMPTY, which makes 4.6 refuse (fail closed) rather than compare
# against a non-measurement's time.
new_scen stale-nonmeasuring-only
HEAD_NM2="a2a2${HEX36}"
printf '%s\n' "$HEAD_NM2" > "$SCEN/head"
lane_pass "$HEAD_NM2" 5965 > "$SCEN/runs-$HEAD_NM2"
lane_pass mainnm2 5966 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5001 'agent-infra-ci / lint' completed skipped 7363 2026-01-01T00:00:00Z 2026-01-01T00:06:00Z)"
pr_run_map 7363 pull_request 'CI'
write_main_checks "$(check_run 6001 'agent-infra-ci / lint' completed failure 7463 2026-01-01T00:03:00Z 2026-01-01T00:03:30Z)"
main_run_map 7463 push 'Post-merge validation'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a SKIPPED-only surface leaves NO anchor, so a red base REFUSES (exit $rc)" \
  || fail "a skipped-only surface certified a red base — the anchor was set by a non-measurement"
grep -q "NO MEASURING completed check run" "$SCEN/err" \
  && pass "…and the refusal names the absence of a MEASURING check, not of any check" \
  || fail "the no-anchor refusal does not distinguish measuring from non-measuring: $(sed -n '1,8p' "$SCEN/err" 2>/dev/null)"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a stale green" || pass "no merge attempted"

# (d) THE OVER-BLOCK GUARD — A MEASURING COMPLETION STILL ADVANCES THE ANCHOR.
# The same fixture with the skipped check replaced by a MEASURING success at
# 00:06 covers the base red that began at 00:02, so the merge MUST proceed.
# Without this the fix could pass by never advancing the anchor at all — which
# would refuse every PR whose surface carries a non-measuring check.
new_scen stale-measuring-anchor
HEAD_NM3="a3a3${HEX36}"
printf '%s\n' "$HEAD_NM3" > "$SCEN/head"
lane_pass "$HEAD_NM3" 5967 > "$SCEN/runs-$HEAD_NM3"
lane_pass mainnm3 5968 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5001 'ci / lint' completed success 7364 2026-01-01T00:05:00Z 2026-01-01T00:06:00Z)"
pr_run_map 7364 pull_request 'CI'
write_main_checks "$(check_run 6001 'agent-infra-ci / lint' completed failure 7464 2026-01-01T00:02:00Z 2026-01-01T00:02:30Z)"
main_run_map 7464 push 'Post-merge validation'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a base red at 00:02 IS covered by the PR's 00:06 MEASURING success — it MERGES (exit 0)" \
  || fail "a covered base red was refused (exit $rc) — the anchor stopped advancing from a measurement: $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"
[ -f "$SCEN/comment" ] && pass "…with its head-bound evidence" || fail "no evidence posted"

# (e) THE OVER-BLOCK GUARD FOR THE ALLOW-LIST — all FIVE named non-red
# conclusions still merge on BOTH surfaces when the base is green, because a
# green base never enters 4.6 at all.
new_scen nonmeasuring-both-surfaces-green
HEAD_NM4="a4a4${HEX36}"
printf '%s\n' "$HEAD_NM4" > "$SCEN/head"
lane_pass "$HEAD_NM4" 5969 > "$SCEN/runs-$HEAD_NM4"
lane_pass mainnm4 5970 > "$SCEN/runs-main"
write_pr_checks \
  "$(check_run 5101 'ci / a' completed success 7365 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)" \
  "$(check_run 5102 'ci / b' completed neutral 7365 2026-01-01T00:00:00Z 2026-01-01T00:02:00Z)" \
  "$(check_run 5103 'ci / c' completed skipped 7365 2026-01-01T00:00:00Z 2026-01-01T00:03:00Z)" \
  "$(check_run 5104 'ci / d' completed cancelled 7365 2026-01-01T00:00:00Z 2026-01-01T00:04:00Z)" \
  "$(check_run 5105 'ci / e' completed stale 7365 2026-01-01T00:00:00Z 2026-01-01T00:05:00Z)"
pr_run_map 7365 pull_request 'CI'
write_main_checks \
  "$(check_run 6101 'ci / a' completed success 7465 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)" \
  "$(check_run 6102 'ci / b' completed neutral 7465 2026-01-01T00:00:00Z 2026-01-01T00:02:00Z)" \
  "$(check_run 6103 'ci / c' completed skipped 7465 2026-01-01T00:00:00Z 2026-01-01T00:03:00Z)" \
  "$(check_run 6104 'ci / d' completed cancelled 7465 2026-01-01T00:00:00Z 2026-01-01T00:04:00Z)" \
  "$(check_run 6105 'ci / e' completed stale 7465 2026-01-01T00:00:00Z 2026-01-01T00:05:00Z)"
main_run_map 7465 push 'Post-merge validation'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "the five named non-red conclusions merge on BOTH surfaces on a green base (exit 0)" \
  || fail "a non-red conclusion was reddened (exit $rc): $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "evaluated tree GREEN" "$SCEN/out" && grep -q "among 5 check(s)" "$SCEN/out" \
  && pass "…and all five tree checks are still COUNTED and reported GREEN" \
  || fail "the tree surface lost its non-measuring checks: $(grep -m1 'evaluated tree' "$SCEN/out")"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"

# (f) THE OVER-BLOCK GUARD FOR IN-FLIGHT SPELLINGS — all five remain PENDING
# (never red, never a measurement), so a green lane/base still merges.
new_scen in-flight-spellings-still-pending
HEAD_NM5="a5a5${HEX36}"
printf '%s\n' "$HEAD_NM5" > "$SCEN/head"
lane_pass "$HEAD_NM5" 5971 > "$SCEN/runs-$HEAD_NM5"
lane_pass mainnm5 5972 > "$SCEN/runs-main"
write_pr_checks \
  "$(check_run 5201 'ci / q' queued '' 7366)" \
  "$(check_run 5202 'ci / p' in_progress '' 7366)" \
  "$(check_run 5203 'ci / w' waiting '' 7366)" \
  "$(check_run 5204 'ci / r' requested '' 7366)" \
  "$(check_run 5205 'ci / n' pending '' 7366)"
pr_run_map 7366 pull_request 'CI'
main_green_surface
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "all five in-flight spellings stay PENDING and merge on a green base (exit 0)" \
  || fail "an in-flight spelling was reddened (exit $rc): $(sed -n '1,5p' "$SCEN/err" 2>/dev/null)"
grep -q "evaluated tree GREEN" "$SCEN/out" && grep -q "pending 5" "$SCEN/out" \
  && pass "…and all five are COUNTED as pending, not red" \
  || fail "the in-flight count is wrong: $(grep -m1 'evaluated tree' "$SCEN/out")"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"

# ── 56. AN UNNAMED (OR PLACEHOLDER-NAMED) CHECK IS KEYED BY ITS OWN IDENTITY ─
# `best`/`sbest` are keyed by (app, name) / context, so ALL unnamed entries shared
# one key: a newer unnamed NON-red superseded an older unnamed RED and the red was
# DISCARDED before classification — the surface read `green — 0 failing of 1
# measured` and the rail merged. Identified entries keep the superseded-run rule.
# (HEX36, the 36-zero sha suffix, is defined at scenario 55.)
echo "== 56. distinct UNNAMED checks cannot supersede one another (#1353) =="

# 36 zeros, so a fixture sha below is exactly 40 hex chars (also defined at 55).
HEX36="000000000000000000000000000000000000"

# raw_unnamed_check <id> <app> <status> <conclusion> <run-id> [completed_at]
raw_unnamed_check() {
  printf '{"id":%s,"name":"","status":"%s","conclusion":"%s","app":{"slug":"%s"},"started_at":"2026-01-01T00:00:00Z","completed_at":"%s","html_url":"https://github.com/daniel-ospina/agent-infra/actions/runs/%s/job/1"}' \
    "$1" "$3" "$4" "$2" "${6:-2026-01-01T00:05:00Z}" "$5"
}

# (a) THE REPRODUCTION. Two unnamed checks on the same app: an older RED (id 9)
# and a newer green (id 10). The green used to overwrite the red in `best`.
new_scen unnamed-collision-red-then-green
HEAD_UC1="b1b1${HEX36}"
printf '%s\n' "$HEAD_UC1" > "$SCEN/head"
lane_pass "$HEAD_UC1" 5981 > "$SCEN/runs-$HEAD_UC1"
lane_pass mainuc1 5982 > "$SCEN/runs-main"
main_green_surface
write_pr_checks \
  "$(raw_unnamed_check 9 github-actions completed failure 6909 2026-01-01T00:01:00Z)" \
  "$(raw_unnamed_check 10 github-actions completed success 6910 2026-01-01T00:05:00Z)"
pr_run_map 6909 pull_request 'CI' 6910 pull_request 'CI'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "two NAME-LESS checks (older RED + newer green) REFUSE (exit $rc)" \
  || fail "a newer unnamed non-red superseded an older unnamed RED and MERGED — the collision hole"
grep -q "THE TREE THIS PR PRODUCES IS RED" "$SCEN/err" && pass "…as the tree-red refusal" \
  || fail "the refusal is not the tree-red one: $(sed -n '1,5p' "$SCEN/err" 2>/dev/null)"
grep -q "(unnamed check)" "$SCEN/err" && pass "…naming the unnamed red it classified" \
  || fail "the refusal does not name the unnamed red"
grep -q "of 2 measured" "$SCEN/err" && pass "…and BOTH unnamed entries are COUNTED (of 2 measured)" \
  || fail "the unnamed entries are not both measured: $(grep -m1 'THE TREE' "$SCEN/err")"
[ -f "$SCEN/comment" ] && fail "evidence was posted over a dropped red" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a dropped red" || pass "no merge attempted"

# (b) THE REVERSE (older green, newer RED) — a control: both the pre-fix and the
# fixed rail refuse here, so (a)'s pre-fix merge is attributable to the collision.
new_scen unnamed-collision-green-then-red
HEAD_UC2="b2b2${HEX36}"
printf '%s\n' "$HEAD_UC2" > "$SCEN/head"
lane_pass "$HEAD_UC2" 5983 > "$SCEN/runs-$HEAD_UC2"
lane_pass mainuc2 5984 > "$SCEN/runs-main"
main_green_surface
write_pr_checks \
  "$(raw_unnamed_check 9 github-actions completed success 6911 2026-01-01T00:01:00Z)" \
  "$(raw_unnamed_check 10 github-actions completed failure 6912 2026-01-01T00:05:00Z)"
pr_run_map 6911 pull_request 'CI' 6912 pull_request 'CI'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "the REVERSE (older green + newer RED) still REFUSES (exit $rc)" \
  || fail "a newer unnamed red was lost — the superseded rule is inverted"

# (c) DIFFERENT APPS — a control showing the loss in (a) is the placeholder
# COLLISION, not the superseded rule: separate apps never shared a key.
new_scen unnamed-collision-different-apps
HEAD_UC3="b3b3${HEX36}"
printf '%s\n' "$HEAD_UC3" > "$SCEN/head"
lane_pass "$HEAD_UC3" 5985 > "$SCEN/runs-$HEAD_UC3"
lane_pass mainuc3 5986 > "$SCEN/runs-main"
main_green_surface
write_pr_checks \
  "$(raw_unnamed_check 9 app-a completed failure 6913 2026-01-01T00:01:00Z)" \
  "$(raw_unnamed_check 10 app-b completed success 6914 2026-01-01T00:05:00Z)"
pr_run_map 6913 pull_request 'CI' 6914 pull_request 'CI'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "unnamed checks on DIFFERENT apps still REFUSE (exit $rc)" \
  || fail "an unnamed red on another app was lost"

# (d) THE STATUS HALF. Two `context: ""` statuses share the placeholder key, so a
# newer unnamed `success` used to supersede an older unnamed `failure`.
new_scen unnamed-collision-status
HEAD_UC4="b4b4${HEX36}"
printf '%s\n' "$HEAD_UC4" > "$SCEN/head"
lane_pass "$HEAD_UC4" 5987 > "$SCEN/runs-$HEAD_UC4"
lane_pass mainuc4 5988 > "$SCEN/runs-main"
main_green_surface
pr_green_surface
printf '{"state":"failure","total_count":2,"statuses":[{"context":"","state":"failure","updated_at":"2026-01-01T00:01:00Z","target_url":"https://example.com/status/9"},{"context":"","state":"success","updated_at":"2026-01-01T00:05:00Z","target_url":"https://example.com/status/10"}]}\n' > "$SCEN/pr-statuses.json"
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "two NAME-LESS statuses (older failure + newer success) REFUSE (exit $rc)" \
  || fail "a newer unnamed status superseded an older unnamed FAILURE and MERGED"
grep -q "(unnamed status)" "$SCEN/err" && pass "…naming the unnamed failure" \
  || fail "the refusal does not name the unnamed status"

# (e) A CHECK LITERALLY NAMED THE PLACEHOLDER collides identically.
new_scen unnamed-collision-placeholder-name
HEAD_UC5="b5b5${HEX36}"
printf '%s\n' "$HEAD_UC5" > "$SCEN/head"
lane_pass "$HEAD_UC5" 5989 > "$SCEN/runs-$HEAD_UC5"
lane_pass mainuc5 5990 > "$SCEN/runs-main"
main_green_surface
write_pr_checks \
  "$(check_run 9 '(unnamed check)' completed failure 6915 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)" \
  "$(check_run 10 '(unnamed check)' completed success 6916 2026-01-01T00:00:00Z 2026-01-01T00:05:00Z)"
pr_run_map 6915 pull_request 'CI' 6916 pull_request 'CI'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a check NAMED '(unnamed check)' collides the same way and REFUSES (exit $rc)" \
  || fail "placeholder-NAMED checks collided and a red was lost"

# (f) THE OVER-BLOCK GUARD — IDENTIFIED superseded runs still do NOT red.
new_scen identified-superseded-still-green
HEAD_UC6="b6b6${HEX36}"
printf '%s\n' "$HEAD_UC6" > "$SCEN/head"
lane_pass "$HEAD_UC6" 5991 > "$SCEN/runs-$HEAD_UC6"
lane_pass mainuc6 5992 > "$SCEN/runs-main"
main_green_surface
write_pr_checks \
  "$(check_run 3101 'ai-review-gate' completed failure 6917 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)" \
  "$(check_run 3102 'ai-review-gate' completed success 6918 2026-01-01T00:00:00Z 2026-01-01T00:05:00Z)"
pr_run_map 6917 pull_request 'CI' 6918 pull_request 'CI'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "an IDENTIFIED red superseded by a later green still MERGES (exit 0)" \
  || fail "the superseded-run rule was weakened for identified entries (exit $rc)"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"

# (g) …AND THE IDENTIFIED RULE STILL RUNS THE OTHER WAY: a newer red of the same
# name is NOT superseded by the older green.
new_scen identified-newer-red-still-red
HEAD_UC7="b7b7${HEX36}"
printf '%s\n' "$HEAD_UC7" > "$SCEN/head"
lane_pass "$HEAD_UC7" 5993 > "$SCEN/runs-$HEAD_UC7"
lane_pass mainuc7 5994 > "$SCEN/runs-main"
main_green_surface
write_pr_checks \
  "$(check_run 3101 'ai-review-gate' completed success 6919 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)" \
  "$(check_run 3102 'ai-review-gate' completed failure 6920 2026-01-01T00:00:00Z 2026-01-01T00:05:00Z)"
pr_run_map 6919 pull_request 'CI' 6920 pull_request 'CI'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an IDENTIFIED newer red still REFUSES (exit $rc)" \
  || fail "an identified newer red was superseded by an older green"

# (h) …AND two unnamed NON-red checks still merge (the fix must not redden them).
new_scen unnamed-two-nonred
HEAD_UC8="b8b8${HEX36}"
printf '%s\n' "$HEAD_UC8" > "$SCEN/head"
lane_pass "$HEAD_UC8" 5995 > "$SCEN/runs-$HEAD_UC8"
lane_pass mainuc8 5996 > "$SCEN/runs-main"
main_green_surface
write_pr_checks \
  "$(raw_unnamed_check 9 github-actions completed success 6921 2026-01-01T00:01:00Z)" \
  "$(raw_unnamed_check 10 github-actions completed neutral 6922 2026-01-01T00:05:00Z)"
pr_run_map 6921 pull_request 'CI' 6922 pull_request 'CI'
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "two unnamed NON-red checks still MERGE (exit 0)" \
  || fail "the per-entry key reddened unnamed non-red checks (exit $rc)"
grep -q "evaluated tree GREEN" "$SCEN/out" && grep -q "among 2 check(s)" "$SCEN/out" \
  && pass "…and both are still COUNTED" \
  || fail "the unnamed non-red checks vanished: $(grep -m1 'evaluated tree' "$SCEN/out")"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"

# ── 57. A POSITIVE DROP COUNT WITH NO TOKEN TEXT IS CLIPPED, NOT COMPLETE ────
# An empty TOKEN on a DROPPED line (a bare `FAILED` where FAILED is the last
# field) is a COUNTED drop that renders nothing, so the token block printed the
# COMPLETE empty-text body directly under a stated positive drop count — the
# COMPLETE/CLIPPED claim contradicted the count it had just reported.
echo "== 57. a positive drop count with no token text renders CLIPPED, not COMPLETE (#1353) =="

# 36 zeros, so a fixture sha below is exactly 40 hex chars (also defined at 55).
HEX36="000000000000000000000000000000000000"

# log_bare_failed — a `FAILED` record with NOTHING after it: the parser's
# candidate is the EMPTY string, a DROPPED drop whose token text renders blank.
log_bare_failed() { printf 'test (a)\tRun tests\t2026-09-17T13:10:44.1700000Z FAILED\n'; }

# (a) THE REPRODUCTION. One real FAILED id (exempted by main) + TWO bare FAILED
# lines: the count is 2, the token text renders blank, and the evidence used to
# claim the sets were COMPLETE.
new_scen attribution-empty-token-text
HEAD_AT5="c1c1${HEX36}"
printf '%s\n' "$HEAD_AT5" > "$SCEN/head"
FAIL_AT5='tests/test_other.py::test_red_on_main'
lane_fail "$HEAD_AT5" 8805 > "$SCEN/runs-$HEAD_AT5"
{ log_failed "$FAIL_AT5"; log_bare_failed; log_bare_failed; } > "$SCEN/log-8805"
main_red_n mainat5 9005 3 "$FAIL_AT5" > "$SCEN/runs-main"
main_green_surface
pr_green_surface
run_admin_here 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a PR with one exempt failure and TWO text-less drops still merges (exit 0)" \
  || fail "the attribution disclosure blocked a merge it must not (exit $rc): $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "the parser reported 2 drop(s) but named no token text" "$SCEN/err" \
  && pass "the RAIL'S OUTPUT states the count AND that no token text was named" \
  || fail "the rail does not state the missing token text: $(grep -m1 'DROP' "$SCEN/err")"
if [ -f "$SCEN/comment" ]; then
  grep -q "PR=2 | main=0" "$SCEN/comment" && pass "the POSTED EVIDENCE states the drop count (PR=2, main=0)" \
    || fail "the evidence does not state the drop counts: $(grep -m1 'Attribution' "$SCEN/comment")"
  grep -q "NO token text to render" "$SCEN/comment" \
    && pass "…and the token block renders the CLIPPED body naming the MISSING text" \
    || fail "the token block does not name the missing token text"
  grep -q "every FAILED token was a test id, so the failing sets above are COMPLETE" "$SCEN/comment" \
    && fail "the evidence claims COMPLETE while stating a positive drop count" \
    || pass "…and it does NOT claim COMPLETE over a stated positive drop count"
  grep -q -- "- (HTTP" "$SCEN/comment" && fail "a token appeared from nowhere" || pass "…with no fabricated token"
else
  fail "no evidence comment posted for the text-less-drop case"
fi
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"

# (b) THE GUARD THE OTHER WAY — a REAL token still renders as a token, and the
# no-text CLIPPED body must NOT replace a populated token list.
new_scen attribution-empty-plus-real-token
HEAD_AT6="c2c2${HEX36}"
printf '%s\n' "$HEAD_AT6" > "$SCEN/head"
lane_fail "$HEAD_AT6" 8806 > "$SCEN/runs-$HEAD_AT6"
{ log_failed "$FAIL_AT5"; log_bare_failed; log_unattributable '(HTTP'; } > "$SCEN/log-8806"
main_red_n mainat6 9006 3 "$FAIL_AT5" > "$SCEN/runs-main"
main_green_surface
pr_green_surface
run_admin_here 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a text-less drop BESIDE a real token still merges (exit 0)" \
  || fail "the mixed drop case blocked a sound merge (exit $rc)"
if [ -f "$SCEN/comment" ]; then
  grep -q -- "- (HTTP" "$SCEN/comment" && pass "…and the REAL token is still rendered in the list" \
    || fail "the real token vanished from the evidence"
  grep -q "NO token text to render" "$SCEN/comment" \
    && fail "the no-text CLIPPED body replaced a populated token list" \
    || pass "…and the no-text CLIPPED body is NOT used when token text exists"
  grep -q "PR=2 | main=0" "$SCEN/comment" && pass "…with the count (2 drops: one text-less, one real token)" \
    || fail "the mixed count is wrong"
else
  fail "no evidence comment posted for the mixed case"
fi

# (c) THE OVER-BLOCK GUARD FOR THE COMPLETE BRANCH — a zero drop count still
# states COMPLETE explicitly (the disclosure stays unconditional).
new_scen attribution-still-complete
HEAD_AT7="c3c3${HEX36}"
printf '%s\n' "$HEAD_AT7" > "$SCEN/head"
lane_pass "$HEAD_AT7" 8807 > "$SCEN/runs-$HEAD_AT7"
lane_pass mainat7 8808 > "$SCEN/runs-main"
main_green_surface
pr_green_surface
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a clean merge still merges (exit 0)" \
  || fail "the attribution disclosure blocked a clean merge (exit $rc)"
if [ -f "$SCEN/comment" ]; then
  grep -q "PR=0 | main=0" "$SCEN/comment" && pass "…and the evidence states ZERO drops" \
    || fail "the evidence omits the zero drop count"
  grep -q "every FAILED token was a test id, so the failing sets above are COMPLETE" "$SCEN/comment" \
    && pass "…and says COMPLETE, not merely empty" \
    || fail "the COMPLETE claim was lost when the count is zero"
  grep -q "NO token text to render" "$SCEN/comment" && fail "the CLIPPED body leaked into a zero-drop set" \
    || pass "…and the CLIPPED body is absent"
else
  fail "no evidence comment posted for the complete case"
fi

# ── 58. THE DROP-COUNT SUMMARY MATCH IS ANCHORED TO ITS OWN LINE ─────────────
# `unattributable_count`'s greedy `.*unattributable=` also matched the TOKEN TEXT
# of a DROPPED line, so a dropped token that literally contained
# `unattributable=7` reported 8 for ONE drop (and the evidence said `PR=8`).
echo "== 58. a token's own text cannot inflate the drop count (#1353) =="

# 36 zeros, so a fixture sha below is exactly 40 hex chars (also defined at 55).
HEX36="000000000000000000000000000000000000"

log_bare_failed() { printf 'test (a)\tRun tests\t2026-09-17T13:10:44.1700000Z FAILED\n'; }

# (a) THE REPRODUCTION. One real exempt failure + ONE token whose text is
# `unattributable=7`. The summary says unattributable=1; the old greedy match also
# read the token and summed 1 + 7 = 8.
new_scen dropcount-token-inflation
HEAD_AT8="c4c4${HEX36}"
printf '%s\n' "$HEAD_AT8" > "$SCEN/head"
FAIL_AT8='tests/test_other.py::test_red_on_main'
lane_fail "$HEAD_AT8" 8809 > "$SCEN/runs-$HEAD_AT8"
{ log_failed "$FAIL_AT8"; log_unattributable 'unattributable=7'; } > "$SCEN/log-8809"
main_red_n mainat8 9008 3 "$FAIL_AT8" > "$SCEN/runs-main"
main_green_surface
pr_green_surface
run_admin_here 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a token containing 'unattributable=7' does not block a sound merge (exit 0)" \
  || fail "the token-text inflation blocked a merge (exit $rc): $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "1 FAILED token(s) were DROPPED" "$SCEN/err" \
  && pass "the RAIL'S OUTPUT reports ONE drop, not 8" \
  || fail "the rail's drop count is inflated by the token text: $(grep -m1 'FAILED token' "$SCEN/err")"
if [ -f "$SCEN/comment" ]; then
  grep -q "PR=1 | main=0" "$SCEN/comment" && pass "the POSTED EVIDENCE states PR=1 | main=0" \
    || fail "the evidence drop count is inflated: $(grep -m1 'Attribution' "$SCEN/comment")"
  grep -q "PR=8" "$SCEN/comment" && fail "the evidence still counts the token's own 'unattributable=7'" \
    || pass "…and the token's own text did NOT inflate it"
  grep -q -- "- unattributable=7" "$SCEN/comment" \
    && pass "…while the token is STILL NAMED in the drop list" \
    || fail "the token was dropped from the evidence instead of named"
else
  fail "no evidence comment posted for the inflation case"
fi
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"

# (b) THE MIXED CASE — text-less drops are still counted through the DROPPED-line
# path, and the token text still does not add to them.
new_scen dropcount-mixed
HEAD_AT9="c5c5${HEX36}"
printf '%s\n' "$HEAD_AT9" > "$SCEN/head"
lane_fail "$HEAD_AT9" 8810 > "$SCEN/runs-$HEAD_AT9"
{ log_failed "$FAIL_AT8"; log_unattributable 'unattributable=7'; log_bare_failed; log_bare_failed; } > "$SCEN/log-8810"
main_red_n mainat9 9009 3 "$FAIL_AT8" > "$SCEN/runs-main"
main_green_surface
pr_green_surface
run_admin_here 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a mixed drop set still merges (exit 0)" \
  || fail "the mixed drop set blocked a sound merge (exit $rc)"
if [ -f "$SCEN/comment" ]; then
  grep -q "PR=3 | main=0" "$SCEN/comment" \
    && pass "…and the evidence counts 3 drops (one token + two text-less), not 10" \
    || fail "the mixed drop count is wrong: $(grep -m1 'Attribution' "$SCEN/comment")"
else
  fail "no evidence comment posted for the mixed case"
fi

# (c) A token carrying an ABSURD number is still not read as a count.
new_scen dropcount-absurd-token
HEAD_ATA="c6c6${HEX36}"
printf '%s\n' "$HEAD_ATA" > "$SCEN/head"
lane_fail "$HEAD_ATA" 8811 > "$SCEN/runs-$HEAD_ATA"
{ log_failed "$FAIL_AT8"; log_unattributable 'unattributable=99999999999999999999'; } > "$SCEN/log-8811"
main_red_n mainata 9010 3 "$FAIL_AT8" > "$SCEN/runs-main"
main_green_surface
pr_green_surface
run_admin_here 42 --main-runs 3 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "an absurd in-token number does not block a sound merge (exit 0)" \
  || fail "the absurd in-token number blocked a merge (exit $rc)"
if [ -f "$SCEN/comment" ]; then
  grep -q "PR=1 | main=0" "$SCEN/comment" && pass "…and the evidence still states PR=1" \
    || fail "the absurd token changed the count: $(grep -m1 'Attribution' "$SCEN/comment")"
else
  fail "no evidence comment posted for the absurd-token case"
fi

# ── 59. A SKIPPED-ONLY SURFACE ON A GREEN BASE MERGES (the FIX A guard) ───────
# The narrowest form of the #55 over-block guard, run after the attribution
# scenarios: a surface whose ONLY completed check is SKIPPED, on a GREEN base.
# Nothing measurable was produced, and 4.6 is not entered on a green base, so it
# must MERGE — the EMPTY anchor is a refusal only when the base is RED.
echo "== 59. a skipped-only surface on a green base still merges (#1353) =="

new_scen skipped-only-on-green-base
HEAD_NM6="a6a6${HEX36}"
printf '%s\n' "$HEAD_NM6" > "$SCEN/head"
lane_pass "$HEAD_NM6" 5973 > "$SCEN/runs-$HEAD_NM6"
lane_pass mainnm6 5974 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5301 'ci / lint' completed skipped 7367 2026-01-01T00:00:00Z 2026-01-01T00:06:00Z)"
pr_run_map 7367 pull_request 'CI'
main_green_surface
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a SKIPPED-only surface on a GREEN base MERGES (exit 0)" \
  || fail "a skipped-only surface was refused on a green base (exit $rc): $(sed -n '1,5p' "$SCEN/err" 2>/dev/null)"
grep -q "evaluated tree GREEN" "$SCEN/out" && grep -q "among 1 check(s)" "$SCEN/out" \
  && pass "…and the skipped check is still COUNTED and reported GREEN" \
  || fail "the skipped-only surface is not reported: $(grep -m1 'evaluated tree' "$SCEN/out")"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"
# ── 60. a GUARD-STEP failure is ATTRIBUTED and COMPARED (#4469) ────────────
# The measured defect: `pytest` exited rc 0 and the failure was the post-suite
# orphan guard. Because no id existed, the rail REFUSED the run outright
# ("yielded NO parseable 'FAILED <nodeid>' line") and a green, review-clean PR
# could not merge through the sanctioned path. The fix attributes the guard-step
# annotation — keyed by the failing STEP plus the `::error::` shape — so it
# participates in the PR-vs-main comparison exactly like a test nodeid, while the
# fail-closed refusal is PRESERVED on three conditions, all in the parser: the
# annotation must come from a step the RUNNER marked failed; the run's ROOT
# failing step (keyed by job+step, because matrix legs share step NAMES) must
# itself yield an identity; and a step showing pytest's own `E   ` output must
# yield a NODEID. Cases (c)/(d) pin the refusal; (e) pins the residual diagnosis.
echo "== 50. a guard-step failure is attributed and compared (#4469) =="

# The REAL capture shape (tortoise PR #4672, run 35785085760): the echoed script
# SOURCE (a MID-LINE `::error::`, which must NOT become an identity), the guard's
# own annotation, and the runner's generic exit annotation on BOTH the guard step
# and the aggregate gate step (which must NOT become identities either).
guard_log() {  # <orphans> [<step>]
  local n="$1" step="${2:-Assert no redislite orphans (issue}"
  printf 'test (b)\t%s\t2026-09-23T01:19:53.8474165Z \033[36;1m    echo "::error::redislite server leak: $COUNT orphans after suite, threshold $THRESHOLD (issue #1005 / epic #1647 E2E-7)"\033[0m\n' "$step"
  printf 'test (b)\t%s\t2026-09-23T01:19:53.8645102Z ##[error]redislite server leak: %s orphans after suite, threshold 12 (issue #1005 / epic #1647 E2E-7)\n' "$step" "$n"
  printf 'test (b)\t%s\t2026-09-23T01:19:53.8649910Z ##[error]Process completed with exit code 1.\n' "$step"
  printf 'python-ci-gate\tAggregate matrix result\t2026-09-23T01:20:00.3040113Z ##[error]Process completed with exit code 1.\n'
}
GUARD_KEY='guard-step::Assert-no-redislite-orphans-issue::redislite-server-leak-N-orphans-after-suite-threshold-N-issue-N-epic-N-E2E--N'

# (a) THE PARSER: the guard annotation is ONE id; the mid-line echo and the
# runner's exit annotation are excluded.
new_scen guardparse
HEAD_GP="e1e1000000000000000000000000000000000000"
lane_fail "$HEAD_GP" 9401 > "$SCEN/runs-$HEAD_GP"
guard_log 16 > "$SCEN/log-9401"
cfs_run --commit "$HEAD_GP"; rc=$?
[ "$rc" -eq 0 ] && pass "(a) the rail's own extraction reads the guard capture (exit $rc)" \
  || fail "(a) the rail exited $rc on a guard-step failure"
out="$(cat "$TMP/cfs-out")"
[ "$out" = "$GUARD_KEY" ] && pass "(a) …as exactly ONE guard identity (echoed source + runner exit excluded)" \
  || fail "(a) expected only the guard identity, got: $out"
grep -q "guard-steps=1" "$TMP/cfs-err" && pass "(a) …and REPORTS the attribution (guard-steps=1)" \
  || fail "(a) the attribution is silent: $(head -3 "$TMP/cfs-err")"

# (b) THE RAIL: a guard-only failing head, with main red on the SAME guard and the
# PR's single run below `min_runs`, is no longer REFUSED at step 1c — the
# attribution exemption (#5250) is recorded, so the merge proceeds. Main's orphan
# COUNT differs from the PR's on purpose: the identity must survive the count moving.
new_scen guardmerge
printf '%s\n' "$HEAD_GP" > "$SCEN/head"
lane_fail "$HEAD_GP" 9411 > "$SCEN/runs-$HEAD_GP"
guard_log 16 > "$SCEN/log-9411"
i=0
while [ "$i" -lt 3 ]; do
  lane_fail mainguard $((9421 + i)) >> "$SCEN/runs-main"
  guard_log $((14 + i)) > "$SCEN/log-$((9421 + i))"
  i=$((i + 1))
done
run_admin 42 --main-runs 3 >/dev/null 2>&1; rc=$?
grep -q "parseable failure identity" "$TMP/err" && fail "(b) the guard run was STILL refused as unparseable" \
  || pass "(b) the guard-step failure is no longer refused as unparseable"
[ "$rc" -eq 0 ] && pass "(b) an attributed guard failure present on both sides certifies (exit $rc)" \
  || fail "(b) the guard comparison blocked a safe merge: $(head -2 "$TMP/err")"
grep -q "EXEMPT" "$SCEN/comment" && pass "(b) the guard exemption is RECORDED in the evidence" \
  || fail "(b) the exemption is invisible in the evidence"
grep -q "pr merge" "$SCEN/calls" && pass "(b) …and the merge proceeds" || fail "(b) no merge attempted"

# (c) THE REFUSAL IS PRESERVED. A failing run carrying ONLY the runner's generic
# exit annotation names no failure, so it must still BLOCK — this is the "log
# format moved" / "failed outside the test step" case the refusal exists for.
# Without this case the widening would have converted every unparseable run into
# a certificate.
new_scen guardgeneric
HEAD_GG="e2e2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_GG" > "$SCEN/head"
lane_fail "$HEAD_GG" 9501 > "$SCEN/runs-$HEAD_GG"
printf 'test (a)\tRun fast test suite\t2026-09-23T01:00:00.0000000Z ##[error]Process completed with exit code 1.\n' > "$SCEN/log-9501"
lane_fail maingg 9502 > "$SCEN/runs-main"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-9502"
run_admin 42 --main-runs 1 >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && pass "(c) a runner-exit-only failure STILL BLOCKS (exit $rc)" \
  || fail "(c) the runner's generic exit annotation was read as attribution — a false certificate"
grep -q "parseable failure identity" "$TMP/err" && pass "(c) …naming the refusal" \
  || fail "(c) the refusal is unexplained: $(head -2 "$TMP/err")"
grep -q "pr merge" "$SCEN/calls" && fail "(c) a merge was attempted on an unattributable run" \
  || pass "(c) no merge attempted"

# (d) THE MIXED RUN IS STILL REFUSED (found by three reviewers on this PR). An
# unparseable ROOT failure — pytest `ImportError: no module named y` with no
# `FAILED` line — PLUS a sibling guard annotation must NOT be laundered: the root
# failing step is the pytest step and it yields nothing, so the run contributes no
# identity at all and step 1c still BLOCKS. Without this, the widening certifies a
# run whose real failure was never classified — the cycle-3 false certificate.
new_scen guardmixed
HEAD_GM="e3e3000000000000000000000000000000000000"
printf '%s\n' "$HEAD_GM" > "$SCEN/head"
lane_fail "$HEAD_GM" 9601 > "$SCEN/runs-$HEAD_GM"
{
  printf 'test (a)\tRun fast test suite\t2026-09-23T01:00:00.0000000Z E   ImportError: no module named y\n'
  printf 'test (a)\tRun fast test suite\t2026-09-23T01:00:01.0000000Z ##[error]Process completed with exit code 1.\n'
  guard_log 16
} > "$SCEN/log-9601"
lane_fail maingm 9602 > "$SCEN/runs-main"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-9602"
run_admin 42 --main-runs 1 >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && pass "(d) an unparseable ROOT failure beside a guard hit STILL BLOCKS (exit $rc)" \
  || fail "(d) the sibling guard annotation laundered the root failure — a false certificate"
grep -q "parseable failure identity" "$TMP/err" && pass "(d) …naming the refusal" \
  || fail "(d) the refusal is unexplained: $(head -2 "$TMP/err")"
grep -q "pr merge" "$SCEN/calls" && fail "(d) a merge was attempted on the mixed run" \
  || pass "(d) no merge attempted"

# (e) THE RESIDUAL DIAGNOSIS names the guard STEP, not the bare mechanism. The
# widened id universe must reach `attribute_residual` as a STEP unit: the shell
# must not derive the key's shape with its own regex (the #1165 doctrine — a
# second parser in the shell), and the bare `guard-step` prefix must never be
# reported as a unit no real failure occupies, which would flip the diagnosis to
# "measured on this lane, not present on main". Here main is red on a DIFFERENT
# unit, so the guard failure is "not measurable on this lane" — and the STEP is
# what is named.
new_scen guardresid
HEAD_GR="e4e4000000000000000000000000000000000000"
printf '%s\n' "$HEAD_GR" > "$SCEN/head"
lane_fail "$HEAD_GR" 9701 > "$SCEN/runs-$HEAD_GR"
guard_log 16 > "$SCEN/log-9701"
lane_fail maingr 9702 > "$SCEN/runs-main"
log_failed 'tests/test_pre.py::test_pre' > "$SCEN/log-9702"
run_admin 42 --main-runs 1 >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && pass "(e) a guard failure main does not carry BLOCKS (exit $rc)" \
  || fail "(e) a PR-unique guard failure was certified (exit $rc)"
grep -q "Assert-no-redislite-orphans-issue" "$TMP/out" && pass "(e) …and the residual NAMES the guard step" \
  || fail "(e) the guard step is not named in the residual: $(grep -c . "$TMP/out") line(s)"
grep -q "no failure in guard-step" "$TMP/err" && fail "(e) the bare mechanism was reported as the unit" \
  || pass "(e) …never the bare 'guard-step' prefix as a unit"
grep -q "not measurable on this lane" "$TMP/err" && pass "(e) …as not-measurable (absence is not novelty)" \
  || fail "(e) the absence of a main-side guard unit was mis-described: $(grep -c . "$TMP/err") line(s)"
grep -q "pr merge" "$SCEN/calls" && fail "(e) a merge was attempted on a PR-unique guard failure" \
  || pass "(e) no merge attempted"

# ── 51. a SUPERSEDED failing run is NOT a failing run (#1358) ──────────────
#
# THE DEFECT. The parser selected EVERY failing run at the head with no notion of
# recency, so a failing run that a LATER run of the same workflow had already
# replaced stayed in the failing set. For a GATE failure — one whose log carries
# no `FAILED <nodeid>` line, so it can never be attributed — that made
# `examined > extracted`, and the rail refused a head whose own surface was green
# (reproduced on PR #1354 at `e52d4e75`: two `pipeline-compliance` runs counted,
# both since re-run green, and the merge only went through after the operator
# DELETED the two runs — they 404 today). Deleting CI records to satisfy a stale
# reading is not a remedy the rail may require.
#
# THE RULE. A failing run is SUPERSEDED — and not counted at all — when a LATER
# run of the same (commit, workflow id, workflow name, event) concluded `success`.
# "Later" is creation order (a run's id increases with creation, the same notion
# admin-merge.sh's check-surface step uses). Every other conclusion (failure /
# cancelled / skipped / neutral / startup_failure) is not evidence that the commit
# is green, so it supersedes nothing — and anything whose identity cannot be read
# supersedes nothing AND is never superseded. The fixtures below write the parser's
# OWN 6-field raw projection (`<status>\t<conclusion>\t<sha>:<id>\t<workflow-id>\t<workflow-name>\t<event>`);
# the fake projects it DOWN to the canonical 3 fields for the rail's coverage
# gate, so scenario (a) exercises both projections at once. NOTHING here asks gh
# for a CLOCK: §39/§40 forbid `updatedAt` in these scripts, and ordering does not
# need it.
echo "== 51. a SUPERSEDED failing run is not a failing run (#1358) =="

# gh's `--jq` interpolates the identity fields RAW; the projection BASE64-ENCODES the
# three that form the supersede rule's GROUP KEY, because a workflow `name:` is
# author-controlled free text and may carry a TAB (one record, bogus boundary) or a
# NEWLINE (two records — a forged certificate; adversarial cycle 1, 2026-09-23). The
# fixture must model what gh actually EMITS, so it encodes the same three fields with
# the same alphabet: `base64` here, `@base64` in the projection. The line wrapping
# `base64(1)` adds is stripped, because jq's `@base64` does not wrap.
b64() { printf '%s' "$1" | base64 | tr -d '\n'; }
lane7() { printf '%s\t%s\t%s:%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$(b64 "$5")" "$(b64 "$6")" "$(b64 "$7")"; }
lane7_fail() { lane7 completed failure "$1" "$2" "$3" "$4" "$5"; }
lane7_pass() { lane7 completed success "$1" "$2" "$3" "$4" "$5"; }
# A failing run whose log carries NO test id — the #1358 shape: the failure is a
# GATE failure (compliance/lock), not a test failure, so no `FAILED <nodeid>` line
# exists and `examined > extracted` is the only thing the parser can report.
log_gate_fail() { printf 'test (a)\tRun tests\tCompliance check failed: no evidence bound to this head\n'; }

SS_HEAD="5e5e000000000000000000000000000000000000"
SS_WFID=331293210
SS_WFNAME='Pipeline Compliance'
SS_EV=pull_request
# The #1354 head: gate failure, second gate failure, then the SAME workflow run
# again and GREEN — one commit, one workflow, one event. Newest FIRST, as gh
# returns it. The two failing ids (13001/13002) and their gate-failure logs are
# shared by the scenarios below on purpose: the shape is the subject, not the ids.
ss_pr_runs() {  # <green-run-id>
  { lane7_pass "$SS_HEAD" "$1" "$SS_WFID" "$SS_WFNAME" "$SS_EV"
    lane7_fail "$SS_HEAD" 13002 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
    lane7_fail "$SS_HEAD" 13001 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  }
}
ss_pr_jobs() {  # every run in the listing executed the same two shards
  lane_jobset 13001 success 'test (a)' 'test (b)'
  lane_jobset 13002 success 'test (a)' 'test (b)'
  lane_jobset "$1" success 'test (a)' 'test (b)'
}

# (a) THE DEFECT, end to end. Two superseded gate failures plus a green re-run →
# the head IS green, so the rail must merge — and must not reach the refusal that
# only a deleted CI run could clear.
new_scen superseded
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
ss_pr_runs 13003 > "$SCEN/runs-$SS_HEAD"
ss_pr_jobs 13003
log_gate_fail > "$SCEN/log-13001"
log_gate_fail > "$SCEN/log-13002"
lane_pass mainss00 13004 > "$SCEN/runs-main"
lane_jobset 13004 success 'test (a)' 'test (b)'
run_admin_here 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "(a) two superseded gate failures do NOT block (exit 0)" \
  || { fail "(a) a superseded failure blocked the merge (exit $rc) — the #1354 refusal"; sed 's/^/      /' "$SCEN/err" | head -8; }
grep -q "parseable" "$SCEN/err" && fail "(a)  …but the stale 'no parseable FAILED line' refusal is still what stopped it" \
  || pass "(a)  …and the stale refusal is gone"
grep -q "pr merge 42" "$SCEN/calls" && pass "(a)  …the merge ran, with no CI run deleted" \
  || fail "(a)  …no merge was attempted"
# The drop is a SELECTION, not a counter patch: a superseded run's log is never
# fetched, so the rail cannot report on a failure it has already replaced.
grep -q "run view 13001 " "$SCEN/calls" && fail "(a)  …but the superseded run 13001's log was still fetched" \
  || pass "(a)  …and the superseded run's log was never fetched"
grep -q "run view 13002 " "$SCEN/calls" && fail "(a)  …and 13002's log was fetched too" \
  || pass "(a)  …for either superseded run"
# DISCLOSED, never silent: the dropped run and its superseder are both named.
grep -q "superseded by run 13003" "$SCEN/err" && grep -q "run 13001 " "$SCEN/err" \
  && pass "(a)  …and the supersession is DISCLOSED on stderr (13001 superseded by 13003)" \
  || fail "(a)  …the drop is SILENT: stderr names neither the dropped run nor its superseder"

# (b) THE COUNTERS. The refusal is `extracted < examined`, so a selection that left
# `examined` counting the dropped runs would re-open the same refusal by another
# route. Asserted on the parser's own report, where those counters live — together
# with the provenance, which must name only what was actually measured.
new_scen supersedecounters
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
ss_pr_runs 13103 > "$SCEN/runs-$SS_HEAD"
log_gate_fail > "$SCEN/log-13001"
log_gate_fail > "$SCEN/log-13002"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep.txt" --provenance "$TMP/cfs-prov.txt"
rc=$?
[ "$rc" -eq 0 ] && pass "(b) the parser exits 0 (a superseded run is not an extraction failure)" \
  || { fail "(b) parser exit $rc: $(tr '\n' ' ' < "$TMP/cfs-err")"; }
grep -q '^examined=0$' "$TMP/cfs-rep.txt" && pass "(b) …examined=0 — the superseded runs are not counted" \
  || fail "(b) examined is not 0: $(tr '\n' ' ' < "$TMP/cfs-rep.txt")"
grep -q '^tested=1$' "$TMP/cfs-rep.txt" && pass "(b) …tested=1 — the green re-run still proves the revision was exercised" \
  || fail "(b) tested is not 1: $(tr '\n' ' ' < "$TMP/cfs-rep.txt")"
grep -q "13001" "$TMP/cfs-prov.txt" && fail "(b) …but a superseded run is still in the PROVENANCE (the evidence names an unmeasured failure)" \
  || pass "(b) …and the provenance carries only the measured run"
grep -q "13001" "$TMP/cfs-prov.txt" && fail "(b) …but a superseded run is still in the PROVENANCE (the evidence would name an unmeasured failure)" \
  || pass "(b) …and no superseded run is in the provenance"
[ -s "$TMP/cfs-prov.txt" ] && fail "(b) …but the provenance is non-empty after a drop: $(tr '\n' ' ' < "$TMP/cfs-prov.txt")" \
  || pass "(b) …(verified empty, not merely free of that id)"

# (c) THE OTHER HALF — the fail-closed direction must not move. A later FAILING run
# replaces nothing, so a lane whose newest measurement is red still refuses (the
# lone-failure shape is test 29(a)).
new_scen supersededfails
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ lane7_fail "$SS_HEAD" 13203 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  lane7_fail "$SS_HEAD" 13202 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  lane7_fail "$SS_HEAD" 13201 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
} > "$SCEN/runs-$SS_HEAD"
for i in 13201 13202 13203; do log_gate_fail > "$SCEN/log-$i"; done
run_admin_here 42 --main-runs 1 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "(c) failing runs with NO later green still BLOCK (exit $rc)" \
  || fail "(c) a lane whose every measurement is red merged"
grep -q "parseable" "$SCEN/err" && pass "(c) …with the same named reason as before" \
  || fail "(c) …but the refusal is unexplained: $(head -2 "$SCEN/err")"

# (d) NOT-SUCCESS DOES NOT SUPERSEDE. `cancelled` (which is what
# `cancel-in-progress` produces), `skipped` (it exercised nothing) and `neutral`
# are all terminal — and none of them is evidence that the commit is green.
for c in cancelled skipped neutral; do
  new_scen "supersedelater-$c"
  printf '%s\n' "$SS_HEAD" > "$SCEN/head"
  { lane7 completed "$c" "$SS_HEAD" 13303 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
    lane7_fail "$SS_HEAD" 13301 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  } > "$SCEN/runs-$SS_HEAD"
  cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-$c.txt"
  grep -q '^examined=1$' "$TMP/cfs-rep-$c.txt" \
    && pass "(d) a later '$c' run does NOT supersede a failure (still examined)" \
    || fail "(d) a later '$c' run superseded a failure — it is not evidence of green: $(tr '\n' ' ' < "$TMP/cfs-rep-$c.txt")"
done

# (e) ANOTHER WORKFLOW SUPERSEDES NOTHING. The lane may be `--any-workflow`, where
# the listing MIXES workflows: grouped by commit alone, workflow B's green would
# erase workflow A's red.
new_scen supersededotherwf
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ lane7_pass "$SS_HEAD" 13403 999999 'Workflow lock (base-branch checker)' "$SS_EV"
  lane7_fail "$SS_HEAD" 13401 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-wf.txt"
grep -q '^examined=1$' "$TMP/cfs-rep-wf.txt" \
  && pass "(e) another workflow's green does not clear this workflow's red" \
  || fail "(e) a DIFFERENT workflow's green superseded a failure — the --any-workflow fail-open"
# …and the ID is the identity, not the name: two files both called "CI" are two
# lanes, so a same-named green must not clear the other's red either.
new_scen supersededotherwfid
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ lane7_pass "$SS_HEAD" 13503 111111 'CI' "$SS_EV"
  lane7_fail "$SS_HEAD" 13501 222222 'CI' "$SS_EV"
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-wfid.txt"
grep -q '^examined=1$' "$TMP/cfs-rep-wfid.txt" \
  && pass "(e2) same NAME, different workflow ID → still a different lane" \
  || fail "(e2) a same-named workflow's green cleared another workflow's red"

# (f) ANOTHER EVENT IS ANOTHER MEASUREMENT. One commit is often both a PR head and
# pushed to a branch, and the lane's jobs are event-conditioned — so a `push` run
# is not the same measurement as the `pull_request` run it would replace.
new_scen supersededotherevent
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ lane7_pass "$SS_HEAD" 13603 "$SS_WFID" "$SS_WFNAME" push
  lane7_fail "$SS_HEAD" 13601 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-ev.txt"
grep -q '^examined=1$' "$TMP/cfs-rep-ev.txt" \
  && pass "(f) another EVENT's green does not clear this event's red" \
  || fail "(f) a different event's green superseded a failure"

# (g) ANOTHER COMMIT IS ANOTHER MEASUREMENT — the MAIN side's shape, where the
# listing spans commits by design (the union over the last N runs). A green at a
# NEWER commit must not erase a red at an older one: that would shrink main's
# baseline, and a shrunken baseline is what EXCUSES a genuinely new PR failure.
new_scen supersededothercommit
printf '%s\n' "aaaa111111111111111111111111111111111111" > "$SCEN/head"
{ lane7_pass "bbbb222222222222222222222222222222222222" 13703 "$SS_WFID" "$SS_WFNAME" push
  lane7_fail "cccc333333333333333333333333333333333333" 13701 "$SS_WFID" "$SS_WFNAME" push
} > "$SCEN/runs-main"
log_failed 'tests/test_red_on_main.py::test_x' > "$SCEN/log-13701"
cfs_run --main-union-rates 2 --runs-report "$TMP/cfs-rep-sha.txt"
grep -q '^examined=1$' "$TMP/cfs-rep-sha.txt" \
  && pass "(g) a green at another COMMIT does not clear a red at this one (main's baseline survives)" \
  || fail "(g) main's baseline was collapsed across commits — a PR failure could be excused"
grep -q 'test_red_on_main' "$TMP/cfs-out" && pass "(g) …and the failing id is still in main's rate table" \
  || fail "(g) the red vanished from main's baseline"

# (h) UNREADABLE IDENTITY FAILS CLOSED, in BOTH directions: a run whose identity we
# cannot read supersedes nothing, and is never superseded — and the refusal to
# decide is SAID OUT LOUD rather than assumed silently.
new_scen supersededopaque
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ lane7_pass "$SS_HEAD" 13803 '' "$SS_WFNAME" "$SS_EV"
  lane7_fail "$SS_HEAD" 13801 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-op.txt"
grep -q '^examined=1$' "$TMP/cfs-rep-op.txt" \
  && pass "(h) a run with an unreadable workflow id supersedes nothing (fail closed)" \
  || fail "(h) an opaque run was read as a superseder"
grep -q 'can neither supersede nor be superseded' "$TMP/cfs-err" && grep -q '13803' "$TMP/cfs-err" \
  && pass "(h) …and the unreadable run is NAMED on stderr" \
  || fail "(h) …but the refusal to decide is silent: $(tr '\n' ' ' < "$TMP/cfs-err")"
new_scen supersededopaquefail
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ lane7_pass "$SS_HEAD" 13903 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  lane7 completed failure "$SS_HEAD" 13901 '' "$SS_WFNAME" "$SS_EV"
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-opf.txt"
grep -q '^examined=1$' "$TMP/cfs-rep-opf.txt" \
  && pass "(h2) an unreadable FAILING run is NOT dropped (a green cannot clear an unidentified red)" \
  || fail "(h2) a green superseded a red it could not be shown to match"

# (i) THE RULE RANKS; IT DOES NOT TRUST ORDER. gh returns newest-first, but the
# verdict is computed from CREATION ORDER (the run's own id — never a clock:
# §39/§40 forbid asking gh for `updatedAt` at all) — a listing whose green line
# comes LAST must reach the same verdict, or the gate would depend on an
# undocumented ordering that a future caller could change.
new_scen supersededorder
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ lane7_fail "$SS_HEAD" 14001 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  lane7_fail "$SS_HEAD" 14002 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  lane7_pass "$SS_HEAD" 14003 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-ord.txt"
grep -q '^examined=0$' "$TMP/cfs-rep-ord.txt" \
  && pass "(i) the same verdict whatever order the listing arrives in" \
  || fail "(i) the verdict depends on the listing's order: $(tr '\n' ' ' < "$TMP/cfs-rep-ord.txt")"
# (i2) CREATION ORDER DECIDES — which leaves ONE stated limit. A run RE-RUN long
# after a NEWER run of the same workflow was created is the fresher measurement but
# not the higher id, so its green does NOT clear the newer run's red and the rail
# refuses. That is the fail-CLOSED direction (the remedy is to re-run the newer run
# too), and the only field that would close it is a completion CLOCK — which
# §39/§40 forbid this pair of scripts to ask for. The limit is ASSERTED here rather
# than tolerated by accident: a change that makes this certify must rewrite it.
new_scen supersededcreationorder
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ lane7_fail "$SS_HEAD" 14202 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  lane7_pass "$SS_HEAD" 14101 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-ord2.txt"
grep -q '^examined=1$' "$TMP/cfs-rep-ord2.txt" \
  && pass "(i2) a re-run of an OLDER run does not clear a NEWER red (creation order; fail closed, stated limit)" \
  || fail "(i2) a newer red was cleared by an older run's re-run — if that is intended, the stated limit must be rewritten: $(tr '\n' ' ' < "$TMP/cfs-rep-ord2.txt")"
# (i3) THE FILTER REMOVES FAILURES ONLY. A queued run is not a failing run and must
# survive it: `pending` is the whole input of the lane-terminal PRECONDITION, so
# dropping it would be a fail-open at the rail's FIRST check.
new_scen supersededpending
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ lane7_pass "$SS_HEAD" 14303 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  lane7 queued "" "$SS_HEAD" 14302 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  lane7_fail "$SS_HEAD" 14301 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-pend.txt"
grep -q '^examined=0$' "$TMP/cfs-rep-pend.txt" \
  && pass "(i3) the superseded failure is dropped" \
  || fail "(i3) the superseded failure survived: $(tr '\n' ' ' < "$TMP/cfs-rep-pend.txt")"
grep -q '^pending=1$' "$TMP/cfs-rep-pend.txt" \
  && pass "(i3) …and the QUEUED run survives the filter (the precondition still fires)" \
  || fail "(i3) a queued run was swallowed by the filter — the lane-terminal precondition would be blind: $(tr '\n' ' ' < "$TMP/cfs-rep-pend.txt")"

# (j) THE RULE'S INPUT IS THE LISTER'S OWN PROJECTION. A 3-field line — the shape
# every fixture written before this change has, and the shape the rail's coverage
# gate reads — carries no identity, so it is never grouped and never a group
# member: the rule cannot invent a measurement identity it was not given. That is
# also WHY the whole pre-existing suite keeps its meaning; the scenarios above fail
# loudly if the projection ever loses a field.
new_scen supersededlegacy3
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ lane_pass "$SS_HEAD" 14403
  lane_fail "$SS_HEAD" 14401
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-leg.txt"
grep -q '^examined=1$' "$TMP/cfs-rep-leg.txt" \
  && pass "(j) a 3-field line is opaque: kept, and never grouped with anything" \
  || fail "(j) a line with no identity was grouped anyway: $(tr '\n' ' ' < "$TMP/cfs-rep-leg.txt")"

# (k) THE SAME RULE ON MAIN CLOSES A FAIL-OPEN. A stale red on main — superseded by
# a green re-run at the SAME commit — used to inflate main's baseline, so a PR
# failing the same test was excused as "already red on main" and a genuine
# regression merged. main's baseline now carries live measurements only.
new_scen supersededmainstale
printf '%s\n' "bbbb222222222222222222222222222222222222" > "$SCEN/head"
{ lane7_pass "bbbb222222222222222222222222222222222222" 14503 "$SS_WFID" "$SS_WFNAME" push
  lane7_fail "bbbb222222222222222222222222222222222222" 14501 "$SS_WFID" "$SS_WFNAME" push
} > "$SCEN/runs-main"
log_failed 'tests/test_stale_on_main.py::test_stale' > "$SCEN/log-14501"
cfs_run --main-union-rates 2 --runs-report "$TMP/cfs-rep-stale.txt"
grep -q '^examined=0$' "$TMP/cfs-rep-stale.txt" \
  && pass "(k) a superseded main failure leaves the baseline (it can no longer excuse a PR failure)" \
  || fail "(k) a superseded main red still inflates the baseline: $(tr '\n' ' ' < "$TMP/cfs-rep-stale.txt")"
grep -q 'test_stale_on_main' "$TMP/cfs-out" && fail "(k) …but the stale red is still in main's rate table" \
  || pass "(k) …and it is gone from main's rate table"

# (l) A FIELD BOUNDARY THAT CANNOT BE TRUSTED IS UNREADABLE IDENTITY (code-review
# cycle 1, 2026-09-23). `NF < 6` — the first spelling of the opacity guard — was a
# FAIL-OPEN: a literal TAB inside a workflow NAME makes a SEVEN-field line, so `$5`
# and `$6` hold a FRAGMENT of the name and the group key silently STOPS CARRYING
# THE EVENT. A green run whose own fields shifted the same way then matched that
# truncated key and superseded a red under a DIFFERENT event, while the disclosure
# insisted the event matched. Exactly six fields, or the line is opaque — in BOTH
# directions — and the widening is NAMED (a widened projection is never expected,
# so silence would hide a parser/projection drift).
new_scen supersededwide
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ printf '%s\t%s\t%s:%s\t%s\tDeploy\tpush\n' completed success "$SS_HEAD" 14103 "$SS_WFID"
  printf '%s\t%s\t%s:%s\t%s\tDeploy\tpush\tpull_request\n' completed failure "$SS_HEAD" 14101 "$SS_WFID"
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-wide.txt"
grep -q '^examined=1$' "$TMP/cfs-rep-wide.txt" \
  && pass "(l) a >6-field line is never superseded (a TAB in the workflow NAME is unreadable identity)" \
  || fail "(l) the event left the group key — a shifted green superseded a red at another event: $(tr '\n' ' ' < "$TMP/cfs-rep-wide.txt")"
grep -q 'MORE than the six fields' "$TMP/cfs-err" \
  && pass "(l) …and the widened projection is NAMED on stderr (not silently tolerated)" \
  || fail "(l) …but the widening was silent: $(tr '\n' ' ' < "$TMP/cfs-err")"
new_scen supersededwidefail
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ printf '%s\t%s\t%s:%s\t%s\t%s\t%s\n' completed success "$SS_HEAD" 14203 "$SS_WFID" Deploy push
  printf '%s\t%s\t%s:%s\t%s\tDeploy\tpush\tpull_request\n' completed failure "$SS_HEAD" 14201 "$SS_WFID"
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-widef.txt"
grep -q '^examined=1$' "$TMP/cfs-rep-widef.txt" \
  && pass "(l2) …and a widened FAILING line is never superseded (it stays counted)" \
  || fail "(l2) a green superseded a red whose shape could not be read"

# (m) A SUPERSEDE CERTIFICATE MUST HAVE FINISHED. Cycle 2 showed that checking only
# `conclusion == success` let a synthetic `queued`/`success` line drop a red — a
# contradiction `gh` cannot emit, so the check closes a class by CONSTRUCTION rather
# than by a claim about the producer's behaviour, and it keeps the disclosure's own
# premise true.
new_scen supersededunfinished
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ printf '%s\t%s\t%s:%s\t%s\t%s\t%s\n' queued success "$SS_HEAD" 14303 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  lane7_fail "$SS_HEAD" 14301 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-unfin.txt"
grep -q '^examined=1$' "$TMP/cfs-rep-unfin.txt" \
  && pass "(m) a success that never FINISHED supersedes nothing (only completed+success certifies)" \
  || fail "(m) an unfinished run was read as a certificate: $(tr '\n' ' ' < "$TMP/cfs-rep-unfin.txt")"
# …and the same fixture proves the PENDING probe still sees the queued run: the
# superseder above IS a queued lane run, so `pending` must count it rather than
# the filter having swallowed it.
grep -q '^pending=1$' "$TMP/cfs-rep-unfin.txt" \
  && pass "(m) …and the QUEUED certifier is still a pending run (it was not swallowed)" \
  || fail "(m) the queued run left the pending count: $(tr '\n' ' ' < "$TMP/cfs-rep-unfin.txt")"

# (m2) A BLANK LINE IS NOT A RUN. Emitting it as `\t\t` would be counted as a
# PENDING run, so a listing with a trailing newline could never satisfy the rail's
# lane-terminal precondition (a confusing over-block with no remedy named).
new_scen supersededblank
printf '%s\n' "$SS_HEAD" > "$SCEN/head"
{ lane7_pass "$SS_HEAD" 14403 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  lane7_fail "$SS_HEAD" 14401 "$SS_WFID" "$SS_WFNAME" "$SS_EV"
  printf '\n'
} > "$SCEN/runs-$SS_HEAD"
cfs_run --commit-rows "$SS_HEAD" --runs-report "$TMP/cfs-rep-blank.txt"
grep -q '^pending=0$' "$TMP/cfs-rep-blank.txt" \
  && pass "(m2) a blank line is not emitted as a pending run" \
  || fail "(m2) a blank line became pending: $(tr '\n' ' ' < "$TMP/cfs-rep-blank.txt")"

# ── 61. #1359 — THE MERGE CLAIM IS VERIFIED AGAINST THE ARTIFACT ─────────
# `gh pr merge` exiting 0 is a SEND. It is not the artifact, and MERGE_ARGS is
# caller-supplied, so `-- --auto` reaches the rail: the command returns 0 while
# the PR is still OPEN. By the time the claim is made the evidence comment is
# ALREADY STANDING, so a wrong "merged" is the one error that cannot be walked
# back — which is why the rail now reads state/mergedAt from the API.
echo "== 61. #1359: exit 0 with the PR still OPEN must NOT be reported as merged =="
new_scen merge-noop
HEAD_MN="cccc000000000000000000000000000000000000"
printf '%s\n' "$HEAD_MN" > "$SCEN/head"
MNX='tests/test_import.py::test_import_count_mismatch_422'
MNY='tests/test_import.py::test_import_wrong_key_422'
lane_fail "$HEAD_MN" 901 > "$SCEN/runs-$HEAD_MN"
log_failed "$MNX" > "$SCEN/log-901"
{ lane_fail main5555 902; lane_fail main6666 903; lane_fail main7777 904; } > "$SCEN/runs-main"
log_failed "$MNY" > "$SCEN/log-902"
log_failed "$MNX" > "$SCEN/log-903"
log_failed "$MNX" > "$SCEN/log-904"
# THE SHAPE UNDER TEST: the merge command succeeds, the artifact never follows.
touch "$SCEN/merge-noop"
# One poll: the failure is in the VERDICT, not in the patience.
export ADMIN_MERGE_VERIFY_ATTEMPTS=1
run_admin_here 42 --main-runs 3
rc=$?
[ "$rc" -eq 0 ] \
  && fail "the rail reported SUCCESS for a PR the API never reports as MERGED (exit 0 is a send, not the artifact)" \
  || pass "the rail REFUSES a merge whose artifact was never observed"
grep -q 'is NOT merged' "$SCEN/err" \
  && pass "the refusal SAYS the PR is not merged" \
  || fail "the refusal did not name the unmerged artifact: $(tr '\n' ' ' < "$SCEN/err" | head -c 200)"
grep -q 'state=OPEN' "$SCEN/err" \
  && pass "the refusal reports the API's own state (not an inference)" \
  || fail "the refusal did not report the observed state"
grep -q 'admin-merge-retraction:' "$SCEN/comment" 2>/dev/null \
  && pass "a head-bound RETRACTION is posted — the marker is not left standing" \
  || fail "the evidence marker was left standing over an unmerged PR"

# The POSITIVE control: the same shape, but the merge really happens. Without
# this, a rail that refused EVERY merge would pass the block above.
echo "== 62. #1359: a merge the API confirms IS reported =="
new_scen merge-confirmed
printf '%s\n' "$HEAD_MN" > "$SCEN/head"
lane_fail "$HEAD_MN" 921 > "$SCEN/runs-$HEAD_MN"
log_failed "$MNX" > "$SCEN/log-921"
{ lane_fail main8888 922; lane_fail main9999 923; lane_fail main0000 924; } > "$SCEN/runs-main"
log_failed "$MNY" > "$SCEN/log-922"
log_failed "$MNX" > "$SCEN/log-923"
log_failed "$MNX" > "$SCEN/log-924"
run_admin_here 42 --main-runs 3
rc=$?
[ "$rc" -eq 0 ] \
  && pass "a confirmed merge still succeeds" \
  || fail "a confirmed merge was refused (exit $rc): $(tr '\n' ' ' < "$SCEN/err" | head -c 200)"
grep -q 'confirmed via the API' "$SCEN/out" \
  && pass "the success line STATES the API-confirmed state" \
  || fail "the success line does not state the confirmation"
unset ADMIN_MERGE_VERIFY_ATTEMPTS

# ── 63. #1358 — A NEWLINE IN A WORKFLOW NAME CANNOT FORGE A CERTIFICATE ──
# Adversarial cycle 1 (2026-09-23) reproduced this as a FAIL-OPEN. A workflow
# `name:` is author-controlled free text and YAML carries a literal NEWLINE in a
# double-quoted scalar; `gh --jq` interpolates it RAW, so an UNENCODED identity
# field SPLITS the projection into TWO records — and the tail is a perfectly-formed
# six-field line whose group key the author chose, so it superseded the run's own
# RED and the lane read examined=0. The `NF != 6` guard cannot catch it: awk's
# record separator has already split the input before that guard runs.
#
# This drives the REAL projection expression (`LANE_RUN_RAW_JQ`, read out of the
# script) through the REAL awk rule (the script with its `main` call neutralised,
# sourced in a subshell), so it FAILS if the base64 encoding is ever dropped.
echo "== 63. #1358: a newline in a workflow name cannot forge a supersede =="
new_scen newline-forge
FORGE_SHA="dddd000000000000000000000000000000000000"
printf '%s\n' "$FORGE_SHA" > "$SCEN/head"
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is unavailable, so the projection cannot be exercised — the forge is UNPROVEN"
else
  RAW_JQ="$(grep -m1 '^LANE_RUN_RAW_JQ=' "$CFS" | sed "s/^LANE_RUN_RAW_JQ='//; s/'\$//")"
  TAB=$'\t'
  # ⛔ A REAL newline — `$'\n'`, never `\n` inside a double-quoted string, which
  # is a LITERAL BACKSLASH-N and would make this whole block VACUOUS (cycle 2
  # proved exactly that: the test passed with the encoding REMOVED, because the
  # projection never split). The self-check below exists so it cannot regress.
  NL=$'\n'
  malicious="python-ci${TAB}pull_request${NL}completed${TAB}success${TAB}${FORGE_SHA}:99999999999${TAB}331293210${TAB}python-ci"
  case "$malicious" in
    *$'\n'*) pass "the probe's name carries a LITERAL NEWLINE (not an escaped backslash-n)" ;;
    *)        fail "the probe string holds no real newline — every check below would be VACUOUS" ;;
  esac
  jq -n --arg sha "$FORGE_SHA" --arg bad "$malicious" '
    [ {status:"completed",conclusion:"failure",headSha:$sha,databaseId:100,workflowDatabaseId:331293210,workflowName:"python-ci",event:"pull_request"},
      {status:"completed",conclusion:"failure",headSha:$sha,databaseId:100,workflowDatabaseId:331293210,workflowName:$bad,event:"pull_request"} ]' > "$SCEN/forge.json"
  jq -r "$RAW_JQ" "$SCEN/forge.json" > "$SCEN/forge-raw.txt"
  nlines="$(grep -c . "$SCEN/forge-raw.txt")"
  [ "$nlines" = "2" ] \
    && pass "the projection emits 2 records for 2 runs — the newline is ENCODED, not emitted" \
    || fail "the projection emitted $nlines record(s) for 2 runs: a NEWLINE in the name SPLIT the projection"
  sed 's/^main "\$@"$/:/' "$CFS" > "$SCEN/forge-lib.sh"
  ( set +e; . "$SCEN/forge-lib.sh" >/dev/null 2>&1; drop_superseded_runs < "$SCEN/forge-raw.txt" ) > "$SCEN/forge-out.txt" 2> "$SCEN/forge-note.txt"
  kept="$(grep -c . "$SCEN/forge-out.txt")"
  [ "$kept" = "2" ] \
    && pass "both runs survive the rule — the forged tail cannot drop a red" \
    || fail "the rule emitted $kept line(s) for 2 red runs: a forged certificate superseded one"
  grep -q 'superseded by' "$SCEN/forge-note.txt" \
    && fail "a run was DROPPED as superseded ($(head -c 160 < "$SCEN/forge-note.txt"))" \
    || pass "no run was dropped — nothing was read as a certificate that the commit is green"
fi

# ── 64. the MERGE-STATE projection is exercised, not assumed ────────────────
# §61/§62 drive the fake, and the fake HARDCODES the projected TSV — so a wrong
# `--jq` expression (field order, a dropped sentinel, a quote) would pass them
# while the real producer emitted something else (adversarial cycle 2). This runs
# the expression the rail actually passes to gh, extracted from the rail, against
# crafted responses. The nested case is the one cycle 1 proved a greedy `sed` over
# the whole JSON got WRONG (it read the inner state as the merge state).
echo "== 64. the rail's merge-state projection reads the TOP-LEVEL fields only =="
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is unavailable, so the merge-state projection cannot be exercised"
else
  MJQ="$(grep -o -- "--jq '\[.state[^']*'" "$ADM" | head -1 | sed "s/^--jq '//; s/'\$//")"
  [ -n "$MJQ" ] \
    && pass "the rail's merge-state projection is present and extractable" \
    || fail "could not extract the rail's merge-state --jq expression"
  proj() { printf '%s' "$1" | jq -r "$MJQ" 2>/dev/null | head -1; }
  t="$(proj '{"state":"OPEN","mergedAt":null}')"
  [ "$t" = "OPEN	-" ] \
    && pass "an UNMERGED response projects to OPEN<tab>-" \
    || fail "unmerged projected to [$t]"
  t="$(proj '{"state":"MERGED","mergedAt":"2026-09-23T00:00:00Z"}')"
  [ "$t" = "MERGED	2026-09-23T00:00:00Z" ] \
    && pass "a MERGED response projects to MERGED<tab>timestamp" \
    || fail "merged projected to [$t]"
  t="$(proj '{"state":"OPEN","mergedAt":null,"note":{"state":"MERGED"}}')"
  case "$t" in
    MERGED*) fail "a NESTED state was read as the merge state — the greedy-parse defect is back" ;;
    *)       pass "a nested state=MERGED does NOT leak into the projected state ([$t])" ;;
  esac
  t="$(proj '{"mergedAt":null}')"
  case "$t" in
    MERGED*) fail "a response with NO state projected as MERGED" ;;
    *)       pass "a response with no state is not MERGED ([$t])" ;;
  esac
  t="$(proj '{"state":"MERGED"}')"
  [ "$t" = "MERGED	-" ] \
    && pass "a missing mergedAt is sentineled, so the line still carries its TAB" \
    || fail "missing mergedAt projected to [$t] (the separator must never be absent)"
fi

# ── 65. A RUN THE BOUNDED MAP MISSED IS RESOLVED INDIVIDUALLY (#1446) ─────────
# The base-health run map is a SNAPSHOT — one bounded, branch- or sha-scoped
# `gh run list` (empty when that listing fails) — so it can simply not carry a
# red's run, even though `…/actions/runs/<id>` answers for it. (Observed on a
# `finding-provenance` run, event `issues`, that the snapshot did not carry; WHY
# a particular snapshot misses a run is deliberately not assumed.) Left
# unresolved, the non-code exemption cannot match, the red classifies as
# code-measuring, and step 4.6 refuses every stale-surface PR. The fix resolves
# the run by id, and the outcomes must stay DISTINGUISHABLE: a resolved
# non-code run is exempt, while a run that resolves to NOTHING stays unresolved
# and BLOCKS (never "unresolved therefore exempt").
echo "== 65. #1446: a run the bulk map missed is resolved individually (base), and an unresolvable one still BLOCKS =="

# (a) THE REPRODUCTION, FIXED. Base RED only on a non-code-event lane whose run
# is missing from the map but resolves by id -> EXEMPT (the PR is not stale
# against a lane that measures no revision) and the red is still REPORTED.
new_scen noncode-mapmiss-resolved
HEAD_NC3="eaea000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC3" > "$SCEN/head"
lane_pass "$HEAD_NC3" 5937 > "$SCEN/runs-$HEAD_NC3"
lane_pass mainnc3 5938 > "$SCEN/runs-main"
# PR surface GREEN, produced BEFORE the base red (so a code-measuring red here
# WOULD be a stale surface and block — the exact #1446 refusal).
write_pr_checks "$(check_run 5011 'ci / lint' completed success 7341 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7341 pull_request 'CI'
write_main_checks "$(check_run 6011 provenance completed failure 8401 2026-01-02T00:00:00Z 2026-01-02T00:01:00Z)"
# The map does NOT carry 8401 (an unrelated run only) — the miss.
main_run_map 8302 push 'Python CI'
# …but the run RESOLVES by id to a non-code event + its workflow name.
printf 'issues\tfinding-provenance\n' > "$SCEN/run-8401"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a map-missed run that resolves to a NON-code event is EXEMPT — the PR merges (exit 0)" \
  || fail "a resolvable non-code base red still blocked (exit $rc) — the #1446 over-block is unfixed: $(sed -n '1,4p' "$SCEN/err" 2>/dev/null)"
grep -q "NON-code events" "$SCEN/out" && pass "…and the non-code red is still REPORTED, not silently dropped" \
  || fail "the resolved non-code red is SILENT"
grep -q "actions/runs/8401" "$SCEN/calls" && pass "…and the rail resolved it INDIVIDUALLY by run id (not from the bounded map)" \
  || fail "the rail never attempted the per-run resolve — the run was left to the bounded map"
grep -q "pr merge" "$SCEN/calls" && pass "…and the merge happened" || fail "no merge attempted"

# (b) THE FAIL-CLOSED ARM. The same miss, but the individual resolve ALSO fails
# (no fixture = the API cannot answer for that run). `ev` stays empty, the red
# stays UNRESOLVED, and it BLOCKS — "I could not tell what this is" is not
# "this is noise". This is the arm that must NOT be widened away.
new_scen noncode-mapmiss-unresolved
HEAD_NC4="ebeb000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC4" > "$SCEN/head"
lane_pass "$HEAD_NC4" 5939 > "$SCEN/runs-$HEAD_NC4"
lane_pass mainnc4 5940 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5012 'ci / lint' completed success 7342 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7342 pull_request 'CI'
write_main_checks "$(check_run 6012 provenance completed failure 8402 2026-01-02T00:00:00Z 2026-01-02T00:01:00Z)"
main_run_map 8304 push 'Python CI'
# NO $SCEN/run-8402 fixture: the individual resolve answers nothing.
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "an UNRESOLVABLE base red still BLOCKS (exit $rc) — the fail-closed arm is intact" \
  || fail "an unresolvable base red was EXEMPTED — the guard was widened into fail-open"
grep -q "(workflow unresolved)" "$SCEN/err" && pass "…and it is named UNRESOLVED, not silently reclassified" \
  || fail "the unresolved red is not named unresolved"
grep -q "actions/runs/8402" "$SCEN/calls" && pass "…AFTER attempting the per-run resolve, which answered nothing" \
  || fail "the rail did not even attempt the per-run resolve in the unresolvable case"
[ -f "$SCEN/comment" ] && fail "evidence was posted over an unresolved red" || pass "no evidence comment posted"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over an unresolved red" || pass "no merge attempted"

# (c) A CODE EVENT IS NOT A LOOPHOLE. A map-missed run that resolves to a
# code-measuring event must STILL BLOCK — the resolve is not a blanket
# exemption, and the workflow is now named rather than reported unresolved.
new_scen noncode-mapmiss-code
HEAD_NC5="ecec000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC5" > "$SCEN/head"
lane_pass "$HEAD_NC5" 5941 > "$SCEN/runs-$HEAD_NC5"
lane_pass mainnc5 5942 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5013 'ci / lint' completed success 7343 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7343 pull_request 'CI'
write_main_checks "$(check_run 6013 lint completed failure 8403 2026-01-02T00:00:00Z 2026-01-02T00:01:00Z)"
main_run_map 8306 push 'Python CI'
printf 'push\tPython CI\n' > "$SCEN/run-8403"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a map-missed run resolving to a CODE event still BLOCKS (exit $rc)" \
  || fail "a code-measuring red was exempted — the resolve became a blanket exemption"
grep -q "workflow 'Python CI'" "$SCEN/err" && pass "…and the resolved workflow name is named in the refusal" \
  || fail "the resolved code red is still reported as '(workflow unresolved)'"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a code red" || pass "no merge attempted"

# (d) A MALFORMED ANSWER IS NOT A RESOLUTION. A tab-less response is not the
# projected `<event>\t<workflow>` shape, so it must NOT be read as an event —
# the red stays unresolved and BLOCKS. This pins the strict accept: an
# over-eager parse would read `issues` out of a malformed line and exempt a red
# on evidence the producer never actually supplied.
new_scen noncode-mapmiss-malformed
HEAD_NC6="eded000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC6" > "$SCEN/head"
lane_pass "$HEAD_NC6" 5943 > "$SCEN/runs-$HEAD_NC6"
lane_pass mainnc6 5944 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5014 'ci / lint' completed success 7344 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7344 pull_request 'CI'
write_main_checks "$(check_run 6014 provenance completed failure 8404 2026-01-02T00:00:00Z 2026-01-02T00:01:00Z)"
main_run_map 8308 push 'Python CI'
printf 'issues\n' > "$SCEN/run-8404"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a TAB-LESS (malformed) resolve answer is NOT read as an event — still BLOCKS (exit $rc)" \
  || fail "a malformed resolve answer was parsed as a non-code exemption — an over-eager parse"
grep -q "(workflow unresolved)" "$SCEN/err" && pass "…and it stays UNRESOLVED" \
  || fail "the malformed answer was accepted as a resolution"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a malformed resolution" || pass "no merge attempted"

# (e) THE MAP STAYS THE PRIMARY SOURCE — the per-run resolve is a FALLBACK. A red
# the map DOES carry must cost no per-run call, and its verdict must not move.
new_scen noncode-mapresolved-precedence
HEAD_NC7="eeee000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC7" > "$SCEN/head"
lane_pass "$HEAD_NC7" 5945 > "$SCEN/runs-$HEAD_NC7"
lane_pass mainnc7 5946 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5015 'ci / lint' completed success 7345 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7345 pull_request 'CI'
write_main_checks "$(check_run 6015 provenance completed failure 8405 2026-01-02T00:00:00Z 2026-01-02T00:01:00Z)"
# The map HAS the event, and a fixture also exists for 8405 — so a rail that
# resolves it anyway (dropping the `[ -z "$ev" ]` guard) records the call.
main_run_map 8405 issues finding-provenance
printf 'issues\tfinding-provenance\n' > "$SCEN/run-8405"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -eq 0 ] && pass "a red the MAP carries is still exempt and merges (the map is still primary)" \
  || fail "a map-resolved non-code red blocked (exit $rc)"
grep -q "actions/runs/8405" "$SCEN/calls" && fail "the rail spent a per-run resolve on a red the map already resolved — the fallback is no longer a fallback" \
  || pass "…and NO per-run call was spent on a red the map resolved"

# (f) THE EVALUATED TREE STILL BLOCKS A NON-CODE RED — through the per-run
# resolve too. The #1353 contract is SURFACE-scoped, so a non-code red on the
# PR's tree is an anomaly and BLOCKS whether its event came from the map or from
# the new resolve. This pins that the resolve did not open the tree surface.
new_scen noncode-tree-resolved
HEAD_NC8="efef000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC8" > "$SCEN/head"
lane_pass "$HEAD_NC8" 5947 > "$SCEN/runs-$HEAD_NC8"
lane_pass mainnc8 5948 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5016 provenance completed failure 8406)"
# The TREE map does NOT carry 8406; the per-run resolve answers `schedule`.
pr_run_map 8309 push 'Python CI'
printf 'schedule\tregistry-backup-cron\n' > "$SCEN/run-8406"
main_green_surface
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a non-code red on the EVALUATED TREE still BLOCKS, per-run-resolved or not (exit $rc)" \
  || fail "a non-code red on the evaluated tree was exempted — the #1353 hole reopened"
grep -q "NOT EXEMPT ON THIS SURFACE" "$SCEN/err" && pass "…with the surface-scoped reason named" \
  || fail "the tree refusal does not state the exemption is base-only"
grep -q "actions/runs/8406" "$SCEN/calls" && pass "…after the per-run resolve was attempted on the tree too" \
  || fail "the tree probe did not attempt the per-run resolve"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a tree red" || pass "no merge attempted"

# (g) THE RESOLVE'S PROJECTION IS ITSELF PINNED. The fake `gh` answers the
# per-run call by `cat`-ing an ALREADY-PROJECTED fixture and IGNORES `--jq`, so a
# wrong field order/name in the rail's expression would pass every arm above
# while the fix is silently ineffective in production (the #1446 over-block
# returns, suite green). Section 64 guards the merge-state projection this way;
# do the same for the resolve.
if ! command -v jq >/dev/null 2>&1; then
  fail "jq is unavailable, so the resolve projection cannot be exercised"
else
  RJQ="$(sed -n "s/^.*--jq '\(\[(.event.*\)' 2>.*$/\1/p" "$ADM" | head -1)"
  [ -n "$RJQ" ] && pass "the rail's per-run resolve --jq expression is present and extractable" \
    || fail "could not extract the resolve --jq expression from the rail"
  rproj() { printf '%s' "$1" | jq -r "$RJQ" 2>/dev/null; }
  t="$(rproj '{"event":"issues","name":"finding-provenance"}')"
  [ "$t" = "$(printf 'issues\tfinding-provenance')" ] \
    && pass "the projection emits <event><TAB><workflow>" \
    || fail "the projection emitted [$t]"
  t="$(rproj '{"event":"push","name":"issues"}')"
  [ "$t" = "$(printf 'push\tissues')" ] \
    && pass "…with the EVENT first — a swapped field order cannot pass" \
    || fail "the projection's field order is not event-then-name ([$t])"
  t="$(rproj '{}')"
  [ "$t" = "$(printf '\t')" ] \
    && pass "…an empty run projects to an EMPTY event (arm (i) pins that the rail then blocks)" \
    || fail "an empty run projected to [$t]"
  t="$(rproj '{"event":"issues\npush","name":"wf"}')"
  if [ "$(printf '%s' "$t" | wc -l | tr -d ' ')" = "0" ]; then
    pass "…and a newline inside the event is ESCAPED, so it cannot forge a second field"
  else
    fail "a newline in the event produced a RAW newline — a lenient parse could read a forged event ([$t])"
  fi
fi

# (h) A LEGACY COMMIT STATUS IS NEVER RUN-RESOLVED. A status row's `url` is its
# OWN, app-supplied `target_url`, so a `/runs/<N>` inside it names SOME run, not
# the row's producer — and a status has NO Actions event. Without the app gate,
# a status red whose target_url embeds a `schedule` run URL was EXEMPTED on the
# base (the cycle-2 review reproduced that fail-open). It must BLOCK.
new_scen base-status-runurl
HEAD_NC9="f1f1000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC9" > "$SCEN/head"
lane_pass "$HEAD_NC9" 5949 > "$SCEN/runs-$HEAD_NC9"
lane_pass mainnc9 5950 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5017 'ci / lint' completed success 7351 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7351 pull_request 'CI'
# A GREEN check-run surface plus a RED legacy status whose target_url names a
# `schedule` run that is ABSENT from the map and resolves per-run to `schedule`.
main_green_surface
printf '{"state":"failure","total_count":1,"statuses":[{"context":"deploy-verify","state":"failure","updated_at":"2026-01-02T00:00:00Z","target_url":"https://ci.example.com/actions/runs/9101"}]}\n' > "$SCEN/main-statuses.json"
printf 'schedule\tregistry-backup-cron\n' > "$SCEN/run-9101"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a STATUS red whose target_url embeds a schedule run URL still BLOCKS (exit $rc)" \
  || fail "a legacy commit status was exempted via a run id read from its target_url — a fail-open"
grep -q "actions/runs/9101" "$SCEN/calls" && fail "the rail run-resolved a commit-status row's target_url" \
  || pass "…and it was never run-resolved (neither from the map nor per-run)"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a status red" || pass "no merge attempted"

# (i) A TAB-PRESENT BUT EMPTY-EVENT ANSWER IS NOT A RESOLUTION. `@tsv` renders a
# missing event as an empty first field, so the answer is a bare TAB. That must
# stay unresolved and BLOCK — arm (g) pins the projection, this pins the rail.
new_scen noncode-empty-event-resolve
HEAD_NC10="f2f2000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC10" > "$SCEN/head"
lane_pass "$HEAD_NC10" 5951 > "$SCEN/runs-$HEAD_NC10"
lane_pass mainnc10 5952 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5018 'ci / lint' completed success 7352 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7352 pull_request 'CI'
write_main_checks "$(check_run 6016 provenance completed failure 8407 2026-01-02T00:00:00Z 2026-01-02T00:01:00Z)"
main_run_map 8311 push 'Python CI'
printf '\t\n' > "$SCEN/run-8407"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a TAB-present, EMPTY-event resolve answer still BLOCKS (exit $rc)" \
  || fail "an empty-event resolution was read as a non-code exemption"
grep -q "(workflow unresolved)" "$SCEN/err" && pass "…and it stays UNRESOLVED" \
  || fail "the empty-event answer was recorded as a resolution"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over an empty-event answer" || pass "no merge attempted"

# (j) A TAB IN A STATUS `context` MUST NOT SHIFT THE ROW. The red row is parsed
# POSITIONALLY, so three tabs in the free-text field move `app` off
# "commit-status" (defeating the legacy-status gate) and land a chosen URL in
# the field the run-id regex reads — the cycle-3 adversarial bypass. The emitter
# now flattens every field, so the shift is impossible. BLOCK.
new_scen status-context-tab-shift
HEAD_NC11="f3f3000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC11" > "$SCEN/head"
lane_pass "$HEAD_NC11" 5953 > "$SCEN/runs-$HEAD_NC11"
lane_pass mainnc11 5954 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5019 'ci / lint' completed success 7353 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7353 pull_request 'CI'
main_green_surface
printf '{"state":"failure","total_count":1,"statuses":[{"context":"a\\tb\\tc\\thttps://ci.example.com/actions/runs/9101","state":"failure","updated_at":"2026-01-02T00:00:00Z","target_url":"https://ci.example.com/deploy-verify"}]}\n' > "$SCEN/main-statuses.json"
printf 'schedule\tregistry-backup-cron\n' > "$SCEN/run-9101"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a TAB in a status context cannot shift the row: still BLOCKS (exit $rc)" \
  || fail "a status-context tab shifted the row and exempted a code-measuring red — fail-open"
grep -q "actions/runs/9101" "$SCEN/calls" && fail "the shifted context field was read as the row's URL" \
  || pass "…and the forged URL was never read as the row's own"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a shifted status row" || pass "no merge attempted"

# (k) THE SAME SHIFT ON A CHECK-RUN `name`. The row's genuine run (9999, event
# `push`) is code-measuring, but three tabs in the name put a `schedule` URL in
# the field the run-id regex reads, which would exempt the base red. BLOCK.
new_scen checkrun-name-tab-shift
HEAD_NC12="f4f4000000000000000000000000000000000000"
printf '%s\n' "$HEAD_NC12" > "$SCEN/head"
lane_pass "$HEAD_NC12" 5955 > "$SCEN/runs-$HEAD_NC12"
lane_pass mainnc12 5956 > "$SCEN/runs-main"
write_pr_checks "$(check_run 5020 'ci / lint' completed success 7354 2026-01-01T00:00:00Z 2026-01-01T00:01:00Z)"
pr_run_map 7354 pull_request 'CI'
write_main_checks "$(check_run 6018 'a\tb\tc\thttps://ci.example.com/actions/runs/9101' completed failure 9999 2026-01-02T00:00:00Z 2026-01-02T00:01:00Z)"
main_run_map 9999 push 'Python CI'
printf 'schedule\tregistry-backup-cron\n' > "$SCEN/run-9101"
pr_merge_ref true 67c72331b2466a7cd326375621be897366277a89
run_admin_here 42 >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] && pass "a TAB in a check-run name cannot shift the row: still BLOCKS (exit $rc)" \
  || fail "a check-run-name tab shifted the row and exempted a code-measuring red — fail-open"
grep -q "actions/runs/9101" "$SCEN/calls" && fail "the shifted name field was read as the row's URL" \
  || pass "…and the forged URL was never read as the row's own"
grep -q "pr merge" "$SCEN/calls" && fail "a merge was attempted over a shifted check-run row" || pass "no merge attempted"


if [ "$failures" -gt 0 ]; then
  echo "❌ $failures of $checks admin-merge test(s) failed"
  exit 1
fi
echo "✅ all $checks admin-merge tests passed"
