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
# Verdicts (issue #513):
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
  clean|clean-micro) ;;
  *) echo "verdict must be 'clean' (or 'clean-micro'); refusing to record '$VERDICT'" >&2; exit 2 ;;
esac
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
# ── Diff binding (#2982) ──────────────────────────────────────────────────
# What a review approves is the DIFF, not the commit sha. Record the sha256 of
# the PR's three-dot diff and carry it INSIDE the signed marker so the
# ai-review-gate can accept a verdict across a merge-only branch update
# (`gh pr update-branch` inserts a merge commit; the head sha moves, the
# reviewed diff does not). Without this, `strict: true` branch protection and
# the gate's sha-binding were jointly unsatisfiable: every update invalidated
# a still-correct verdict, so a green PR could never reach a terminal
# mergeable state (#2982).
#
# The bytes MUST come from the GitHub REST API, exactly as the workflow does —
# a local `git diff` would not byte-match and every diff= marker would fail
# closed. Hash the FILE, not a command substitution: `x="$(cmd)"` strips
# trailing newlines and would change the digest.
#
# Empty when gh/API/openssl is unavailable → the marker falls back to the
# legacy sha-only shape, and the gate's sha-match path still governs.
DIFF_HASH=""
diff_hash_for_pr() { # <pr> — print the sha256 of the PR's current diff, or nothing
  local pr="$1" tmp
  command -v gh >/dev/null 2>&1 || return 0
  command -v openssl >/dev/null 2>&1 || return 0
  tmp="$(mktemp 2>/dev/null)" || return 0
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN 2>/dev/null || true
  if gh api -H "Accept: application/vnd.github.v3.diff" \
       "repos/$REPO/pulls/$pr" > "$tmp" 2>/dev/null && [ -s "$tmp" ]; then
    openssl dgst -sha256 < "$tmp" | awk '{print $NF}'
  fi
  rm -f "$tmp"
}
if [ -n "$REPO" ]; then
  DIFF_HASH="$(diff_hash_for_pr "$PR")"
  [[ "$DIFF_HASH" =~ ^[0-9a-f]{64}$ ]] || DIFF_HASH=""
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
      PRIOR_LINE="$(printf '%s\n' "$PRIOR_BODY" | grep -E "^review recorded: reviews/${PR}\.json verdict=${VERDICT} @ [0-9a-f]{40} diff=${DIFF_HASH} \(.*\) sig=[0-9a-f]{64}$" | head -1 || true)"
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
if [ -n "$REPO" ]; then
  if [ -n "${DIFF_HASH:-}" ]; then
    printf '{"pr":%d,"head_sha":"%s","verdict":"%s","repo":"%s","diff_sha256":"%s","reviewed_at":"%s"}\n' \
      "$PR" "$SHA" "$VERDICT" "$REPO" "$DIFF_HASH" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP"
  else
    printf '{"pr":%d,"head_sha":"%s","verdict":"%s","repo":"%s","reviewed_at":"%s"}\n' \
      "$PR" "$SHA" "$VERDICT" "$REPO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP"
  fi
else
  printf '{"pr":%d,"head_sha":"%s","verdict":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$SHA" "$VERDICT" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$TMP"
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
