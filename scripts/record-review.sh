#!/usr/bin/env bash
# record-review.sh <pr> <head_sha> [verdict] [repo] [--evidence <artifact>]
#
# record-review.sh --print-tier <pr> [owner/repo]
#   READ-ONLY: print `<status>\t<tier>` for the PR's CURRENT head and exit
#   WITHOUT writing a record. `<tier>` is the HIGHEST verdict tier the diff's
#   SURFACES justify — `full`, `low` or `micro` (see review_tier_cap below);
#   `<status>` is `ok` when the diff was read, otherwise `empty` (no changed
#   files) | `too_large` (a possibly-truncated list) | `unclassified` (the API
#   ANSWERED with a payload this classifier cannot certify — positive evidence,
#   no tier) | `unavailable` (transport failure), and every non-ok status is
#   paired with an EMPTY tier so a degraded read can never be mistaken for a
#   selection.
#   This is the SELECTOR the lane path reads: it answers "which tier does this
#   diff earn?" from the changed paths alone, so review depth is chosen from
#   WHAT THE CHANGE CAN BREAK rather than from how small it looks. `clean` is
#   always permitted at any tier (a stronger claim is never false), so this caps
#   the shallow tiers and never FORCES one.
#
# record-review.sh --print-diff-hash <pr> [owner/repo]
#   READ-ONLY (#1351): compute the PR's live normalized three-dot diff digest
#   and print `<status>\t<hash>` on stdout, then exit WITHOUT writing a record.
#   This is the consumer seam for the local merge gate
#   (extensions/review-enforcer/index.ts), which must compare a recorded
#   `diff_sha256` against the PR's CURRENT diff the SAME way the GitHub
#   ai-review-gate's rule (b) does. The diff machinery below
#   (`diff_hash_for_pr`, the #1398 size-cap local fallback, and
#   scripts/lib/diff-normalize.py) is DELIBERATELY the one implementation: a
#   second hashing path would be a second definition of "unchanged" for one
#   cross-repo contract.
#   status is one of ok | empty | too_large | nondiff | unavailable (the same
#   classification the record path uses); ONLY `ok` carries a hash, and an
#   empty or non-diff body NEVER does. Exit 0 — the status field carries the
#   outcome, so a non-zero exit stays reserved for a usage/argument error.
#
# record-review.sh --check-carry <pr> [owner/repo] [--recorded-diff <64hex> [--recorded-head <40hex>]]
#   READ-ONLY, and the ONE way a lane asks "my record's head is stale — is the
#   diff I reviewed still the diff that would merge?". It runs the SAME
#   `diff_hash_for_pr` the record path and the GitHub gate use, compares that
#   digest to the record's `diff_sha256` with the merge gate's own identity rule
#   (full lowercase 64-hex, never the empty-body constant), and prints ONE
#   tab-separated line `<verdict>\t<record digest|->\t<live digest|status>`.
#   verdict, and exit code:
#     head        0  the record is bound to the CURRENT head — nothing is stale
#     carry       0  the reviewed DIFF is unchanged; the gate carries the record
#     carry-patch 6  the RENDERED diff moved but the reviewed PATCH is
#                    byte-identical (a rebase / base-move) — the gate will NOT
#                    carry the record as-is, so RE-RECORD at the current head
#                    and do NOT run a review cycle (#1377). Distinct from
#                    `carry` because the record must be re-minted, and distinct
#                    from exit 0 because no merge may be assumed.
#     fresh       1  the DIFF changed; a fresh review is genuinely owed
#     unreadable  3  the live diff could not be READ — RETRY, do NOT re-review
#     norecord    4  no record for this PR/repo — there is no verdict to carry
#                    (with no repo resolved: no unique `<owner>-<repo>-<pr>.json`
#                    and no repo-less `<pr>.json` — pass owner/repo)
#     nodigest    5  the record has no usable digest — re-run the recorder at the
#                    head and let its carry arms decide (a CARRY, not a review)
#   A usage/argument error is exit 2. ⛔ It is a PREDICTION, not an authorization:
#   the merge gate re-decides on the live diff, and it never writes a record.
#
#   ── #3315: WHO OWNS THE CARRY VERDICT ──────────────────────────────────────
#   The pair of arguments after the repo exists so that this predicate can answer
#   for a record read from the PR BODY instead of from this box's record file:
#     --recorded-diff <64hex>   the recorded `diff_sha256`
#     --recorded-head <40hex>   the head it was minted at (optional, but it is
#                               what lets a REBASE be answered `carry-patch`
#                               instead of `fresh`)
#   WHY. Two gates read one review record and disagreed about it: this mode said
#   "the reviewed DIFF is UNCHANGED — carry it, do NOT re-review" from the record
#   FILE, while check-pipeline-compliance.sh's check (c) refused the same record
#   because the marker in the body named an earlier head. Check (c) runs on a CI
#   runner, which has no `$HOME/.pi/agent/reviews`, so it could never carry — the
#   only way through was minting an UNATTESTED marker at the current head, which
#   is precisely the falsified-evidence shape tortoise#7391 forbids ("naming the
#   PR's current head is not evidence"). Rather than let the gate grow a second
#   copy of "unchanged", the gate now HANDS the recorded pair in and this file
#   answers — same `diff_hash_for_pr`, same identity rule, same verdict.
#   ⛔ A supplied pair is not TRUSTED more than a record file (anyone who can
#   edit the body can write one, exactly as anyone with write access to the box
#   can write the file); what this mode decides is CONTENT IDENTITY, and whether
#   a marker is AUTHENTIC is the signed-marker gate's question (#784/#2055). A
#   forged pair buys nothing a forged marker line did not already buy check (c),
#   and it still has to equal the live diff the gate computes for itself.
#   Both values are validated at argument time (64-hex / 40-hex, exit 2 on a
#   malformed one), and they are read-only inputs: this never mints, never
#   rebinds a head, and never writes.
#
# record-review.sh --recover-body <pr> [owner/repo]
#   REBUILD a MISSING record from the PR body's own SIGNED marker (#2872).
#   That marker is signed only when key and openssl both work (HMAC-SHA256 over
#   the text, $AI_REVIEW_GATE_KEY, #2055; else UNSIGNED, :4827-4833). A **SIGNED** marker
#   reaches CI in TWO copies (the body; the admitted comment this recorder also posts at
#   :1305, from post_marker_comment), an UNSIGNED one in ONE (:1197). The per-box record
#   does not travel, so a review minted on a cell leaves the rail at NO-RECORD while the proof travels.
#   Measured 2026-10-26: of 45 open PRs, 12 had a marker whose `diff=` equals the
#   PR's live diff and no record file here; the registry covered 2 of them.
#   It verifies the HMAC before minting (a body is attacker-writable, so a
#   shape-only `sig=[0-9a-f]{64}` check would let `sig=<64 zeros>` be adopted and
#   then RE-SIGNED by a later carry — the failure #784/#2055 closed), refuses to
#   overwrite a record that exists, and stamps `"mint":"recovered-body"` plus
#   the marker's `sig` so the provenance is readable.
#   ⛔ `reviewed_at` IS A LOWER BOUND, NOT A MINT TIME. This box never saw the
#   mint, and a marker carries no timestamp. The record's date is the HEAD
#   COMMIT's committer date (a committer can move that with GIT_COMMITTER_DATE,
#   so it bounds the mint from below and no more), and `recovered_at` records when
#   the restoration happened. That is NOT tortoise#7391 satisfied — it is the
#   honest version of an unknown, labelled as one. It also orders safely:
#   `registry-sync.sh` compares records on `reviewed_at`, so a recovered record
#   yields to a peer record with a later stamp instead of overwriting it.
#   ⛔ A `clean-low` MARKER IS REFUSED (exit 3): that tier certifies the merge
#   BASE, `merge_base_sha` is not in the marker, and a recovered clean-low would
#   make the rail skip its base guard while the gate blocks the same record.
#   Mint it again at the current head instead — a FRESH mint, not a carry (there
#   is no prior record to carry from, and the clean-low content-shape guard still
#   has to pass). Calling it a "carry" would name a `mint` state that will not
#   appear in the record.
#   It does NOT review and does NOT authorize a merge: the normal carry arms
#   still decide whether the recovered digest covers what would merge.
#   ⛔ IT WRITES ON THE PR, WHICH IS WHY THIS PARAGRAPH EXISTS (#3168 review).
#   Success also attempts to publish the RECOVERED marker to the durable comment
#   channel (#1224 producer half) — best-effort, and it cannot change the exit
#   code or the stdout tuple, because that tuple is a machine-readable contract.
#   The post goes to STDERR for the same reason. Read this verb as "writes one
#   local record AND may append one PR comment", not as the read-only verb its
#   siblings are.
#     exit 0  minted (stdout: `recovered\t<head>\t<digest|->`)
#     exit 2  usage — an unresolvable repo (a record is identified by PR *and*
#             repo), a minting flag it must not take, or a second verb on the
#             same command line (one verb per invocation: a silently-dropped
#             `--recover-body` would look like a successful recovery)
#     exit 3  NOTHING WRITTEN, and each cause is named on stderr:
#               · no USABLE marker — absent, unsigned, bad signature, or one
#                 naming a DIFFERENT repo
#               · a `clean-low` marker (see above)
#               · no AI_REVIEW_GATE_KEY, so a marker's signature cannot be
#                 VERIFIED (and an unverified marker is a body edit)
#               · the PR body could not be READ — TRANSIENT (RETRY) or PERMANENT
#                 (a 404/422: the PR does not exist or is not visible to this
#                 token — retrying cannot help), branched on gh's own message
#               · the head commit's committer date could not be read, so even a
#                 lower bound for `reviewed_at` cannot be stated — likewise
#                 branched transient vs permanent (`No commit found` = a
#                 force-pushed marker head, or a commit only on a fork)
#     exit 5  recovery fills an ABSENCE and never replaces one: a record for this
#             PR/repo already exists (including one that appeared WHILE this verb
#             was reading the PR), the qualified file embeds ANOTHER repo — the
#             identical-slug overwrite state, which the gate reads as absent but
#             which this verb will not destroy — or an existing record is NOT
#             usable (truncated/hand-edited), which is named with a move-aside
#             remedy (do NOT read that as "a verdict already exists, do nothing")
#
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
# --expect-head <40-hex> (any position): record ONLY if the PR head the rail
# resolves is exactly this sha, otherwise refuse (exit 3) and name the
# divergence. Without it, a reviewer who names the tree they reviewed can have
# that statement overridden: GitHub can leave `refs/pull/<n>/head` behind the
# branch it tracks, and the #2982 carry arm then re-points the record at the PR
# head while printing that the diff is unchanged — true of the PR head, but NOT
# an answer to "record this sha". tortoise#9492.
#
# --evidence <artifact> — REQUIRED to mint a `clean` record (issue tortoise#7391).
# Names the review artifact this verdict rests on, one of:
#   comment:<id>            a PR issue comment        (this fleet's convention)
#   review:<id>             a PR review
#   review-comment:<id>     an inline review comment
#   <a GitHub URL>          any of the three, pasted (…/pull/N#issuecomment-ID,
#                           #discussion_rID, #pullrequestreview-ID)
# The script then VERIFIES it: it must exist, belong to THIS PR, POSTDATE the
# recorded head's commit, and NOT assert an UNRESOLVED outcome. THREE ARMS, and
# the split between them is the whole contract:
#   (1)  the review skills' own exit markers — Auto-fix stalled/failed/reached/
#        aborted/converged/stuck, "N issues remain", "requires human
#        attention/input/review", "test review capped", [ADVERSARIAL-BOUND].
#        UNCONDITIONAL.
#   (1b) a DECLARED negative outcome — an `Outcome: not-clean` line, or a
#        "Review — NOT CLEAN" header. UNCONDITIONAL, and checked BEFORE (2) so a
#        body cannot declare both and be accepted.
#   (2)  the loose `not…clean` substring. It is prose, so it fires ONLY when the
#        artifact states no explicit `Outcome:` field: a review that describes
#        fail-closed code legitimately contains these words (tortoise#8866).
#        NOTE: no review-skill template emits an `Outcome:` field — it is an
#        ad-hoc convention, so its absence is the normal case.
# Anything it cannot verify — including an unreachable API — REFUSES (exit 3). Until
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
#   not-clean   — THE NEGATIVE VERDICT (agent-infra#3400). A review that found a
#                 defect could not be recorded at all: the verdict list admitted
#                 only the three `clean*` tiers, so the ONLY way to write down
#                 "a review ran here and it was not clean" was a PR comment that
#                 no gate reads. That is how tortoise#3295 came to carry
#                 `verdict=clean` in its body while the most recent review at
#                 that head was NOT CLEAN — the contradiction had nowhere to
#                 live except prose.
#                 A not-clean record is the SAME attestation shape as `clean`:
#                 same head binding, same `diff=`, same `sig=`, and --evidence is
#                 required and VERIFIED exactly as for `clean` (a negative
#                 verdict is still a claim that a review happened, so it must
#                 name the artifact). Two differences, both in the direction of
#                 saying MORE:
#                   * `--findings N` is REQUIRED (a not-clean verdict with zero
#                     findings is a contradiction) and is recorded as
#                     `"findings":N`, so the gate can say "reviewed NOT CLEAN at
#                     <sha>: N open finding(s)" instead of "no record";
#                   * the evidence's NEGATIVE assertions are EXPECTED rather than
#                     vetoed — `verify_review_evidence`'s (1)/(1b)/(2) arms exist
#                     to stop a clean mint over a NOT-CLEAN artifact, and
#                     inverting them here would refuse the only correct evidence
#                     a negative verdict can have. Every structural arm (exists,
#                     belongs to THIS PR, postdates the head, is not a record
#                     marker) still applies.
#                 ⛔ IT DOES NOT WEAKEN THE CLEAN PATH. `not-clean` is NOT in the
#                 merge gate's ACCEPTED_VERDICTS (extensions/review-enforcer), so
#                 recording one BLOCKS a merge rather than licensing it — which is
#                 the whole point: the verdict is now legible to the gate instead
#                 of invisible to it.
set -euo pipefail

# ⛔ THE RESERVE IS SPENT BY LANDINGS ONLY — AND "THE RESERVE" IS NOT THIS SCRIPT (#2342 review, P1).
# `gh-limit.py` keeps a reserve below `GH_LIMIT_CORE_FLOOR` (default 800) and refuses a core-only read
# that could not be served from GraphQL. This file used to carry a file-scope
# `export GH_LIMIT_ESSENTIAL=1` here, which made EVERY `gh` in this script — and in every child it
# spawns — exempt from that floor. That is the opposite of the policy the layer states
# (`gh-limit.py::essential()`: "A poll is never essential"; docs/ops/gh-rate-limits.md:454): the
# floor's reason to exist is the spend measured on THIS rail's own poll loops, so exempting them left
# the guard unable to fire on its target. ⛔ AND IT BOUGHT THE LANDING'S WRITE NOTHING: `essential()`
# has exactly one call site, on the NON-mutating arm — a write is refused only by the dated-empty
# guard, which never consults it. The one in-tree declaration is therefore per call, on the read a
# landing genuinely cannot do without: `repo-authority.sh::required_checks`
# (`GH_LIMIT_ESSENTIAL=1 "$gh" api …/protection/required_status_checks`).

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
# SAME constants.
#
# The CROSS-SCRIPT INVARIANT is scoped to the keyword CLASS and its BOUNDARY, not
# the position rule: REFCTX, CLOSING_KW and CLOSING_KW_BOUNDARY are byte-identical
# across the two scripts, pinned mechanically by record-review.test.sh §8.13. The
# #513 tier guard below does NOT rely on the positional rule for GitHub parity —
# GitHub auto-closes a mid-sentence ref, so the guard ALSO scans with the
# BOUNDARY-ANCHORED CLOSING_KW (passing `${CLOSING_KW_BOUNDARY}${CLOSING_KW}` as
# closing_issue_refs' optional <kw-pattern>) and refuses when a non-micro ref
# appears in either scan. The boundary is load-bearing in the FALSE-REFUSAL
# direction: the keyword class is a SUFFIX of ordinary English words ("prefix",
# "discloses", "unresolved"), so an unanchored scan reads `The prefix #42 is
# unrelated.` as `fix #42`, fetches #42's labels, and refuses a record GitHub
# would never auto-close — a false refusal, and strictly BROADER than GitHub,
# which requires a word boundary. It is ALSO load-bearing in the fail-OPEN
# direction (#1336): `\b` does not fire after `_` (`_` is a word character), so
# a mid-sentence `_closes #N_` — which GitHub DOES close — was invisible to the
# guard. See CLOSING_KW_BOUNDARY below for the measured parity. Scoping the
# invariant to the class and boundary is what keeps the positional rule
# (check (a), anti-#968) from becoming a tier-guard fail-open.
# Top-level + guarded main below: this function is source-reachable by tests.
REFCTX='^[[:space:]]*(([-*+]|[0-9]+[.)])[[:space:]]+|#{1,6}[[:space:]]+|>[[:space:]]*)*(\[[ xX]\][[:space:]]+)*[*_`]{0,3}[[:space:]]*'
CLOSING_KW='(fix(es|ed)?|close(s|d)?|resolve(s|d)?)'
# The GitHub-parity keyword BOUNDARY (#1336): the position wrapper composed in
# front of CLOSING_KW by BOTH mid-sentence scans (this file's #513 tier guard and
# check-pipeline-compliance.sh's all_close_refs). It REPLACES `\b`, which does
# NOT fire after `_` (`_` is a word character), so a mid-sentence `_closes #N_` —
# which GitHub DOES close — was invisible to the guard, and a non-micro issue
# could be recorded clean-micro with the guard silent. It admits an emphasis
# OPENING run (`[*_]{0,3}`) only where the run itself starts at a word boundary
# (line start or a non-word char); `[^[:alnum:]_]` (not `[^[:alnum:]]`) is what
# keeps `foo_closes #N` from being read as a keyword — GitHub ignores it, so
# refusing on it would be the false refusal `\b` was chosen to avoid. Measured
# parity lives at check-pipeline-compliance.sh's copy; keep this line
# byte-identical (record-review.test.sh §8.13 pins it).
CLOSING_KW_BOUNDARY='(^|[^[:alnum:]_])[*_]{0,3}'
closing_issue_refs() {
  # <kw-pattern> (optional) selects the keyword class WITHOUT the positional
  # REFCTX prefix — the GitHub-parity scan the tier guard unions in. Callers
  # pass a BOUNDARY-ANCHORED pattern (`${CLOSING_KW_BOUNDARY}${CLOSING_KW}`):
  # without the boundary the class matches inside English words and the scan is
  # BROADER than GitHub (false refusals). Default is the positional form
  # "${REFCTX}${CLOSING_KW}", mirroring
  # check-pipeline-compliance.sh::parse_issue_ref.
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
#   * check-pipeline-compliance.sh::pr_is_artifact_only is the artifact class
#     check (a) reports on (it gated (a)'s closure fallback until #1630; it now
#     only words (a)'s PASS line, so it no longer decides any verdict): it
#     admits ANY file under docs/ (so `docs/evil.sh` would
#     be an "artifact"), the instruction-layer Markdown class (agent-executable
#     instructions — the template is the source that
#     materializes into every repo's AGENTS.md) and the review-routing config (review
#     routing — enforcement input). No line numbers cited for either class:
#     the sibling was already 5 lines out when checked (2026-10-06), and the
#     other is moved by any edit above it — as this very change demonstrates —
#     so `file::function` is the stable citation.
#   * extensions/verification-gate::isShapeExemptFile is a LOCAL
#     pre-flight skip; it admits .md/.css/.html ANYWHERE, including build
#     inputs such as templates/AGENTS.base.md. (After #1409 the artifact class
#     admits that path too, but for a different reason and a different job:
#     check (a) asks "is this PR traceable to an issue" — a closing keyword or a
#     non-closing traceability one, since #1630 — while the attestation class
#     asks "is this diff inert enough to carry a merge attestation". The
#     divergence stands and is deliberate.)
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
# a docs path. (The adjacent gate ACCEPTS `copied` for its artifact class,
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

# ── The review-surface cap: the ALWAYS-FULL class ─────────────────────────
# A verdict tier is a DEPTH choice for a diff whose blast radius is genuinely
# smaller — that is what `proportional-gates` §Review Cycles decides and what
# #1348 gives content-only diffs as `clean-low`. This is the CEILING on that
# choice, and it is keyed on WHAT A CHANGE CAN BREAK, never on how small it
# looks: a one-line edit to the merge rail is a high-blast change; a 300-line
# prose rewrite is not. Diff SIZE is deliberately not an input — the fleet's own
# measurement (2026-10-23) is that a reviewer's cost is FLAT in diff size (a
# 5-line shell fix reviewed at 1.73M tokens vs 3.06M for a 36-line test fixture,
# because the cost is context, not lines), so a "small diff, shallow review"
# tier buys nothing while inviting a genuinely dangerous diff to look cheap.
#
# Declared ONCE here, and consumed by every tier below, so there is no second
# list to drift. It is a HAND-MAINTAINED denylist on purpose: the surfaces that
# can break the product are a short, stable, reviewable set, and a computed
# dependency graph would be a second definition of "what this can affect" — the
# exact class of drift `clean_low_path_ok` also refuses to inherit from a
# sibling (see the class notes above). Surfaces:
#   * the merge/land/repair rails — their correctness IS the product's gates, so
#     a defect here is a false PASS at the last gate before main;
#   * `record-review.sh` itself — the producer of the attestation this cap
#     protects; leaving it out would be a one-line bypass — and
#     `scripts/lib/diff-normalize.py`, the SINGLE implementation of the diff
#     digest (`--print-diff-hash`'s contract). The same argument applies to it
#     verbatim: the file's own #1362 note records that a normalizer which prints
#     nothing yields `DIFF_HASH = sha256("")`, a constant that collides for
#     every diff and lets the carry arm mint head-bound evidence for an
#     unreviewed revision — a FALSE ACCEPT, which is what this class is for;
#   * `scripts/check-*`, `.husky/**` — CI and pre-commit gate bodies: the same
#     "correctness IS a gate" argument as the rails above. NOTE the BOUNDARY
#     here, stated so the list does not grow without one: the class is the
#     surfaces whose own correctness is a gate, NOT every script. `scripts/`
#     outside those names is reviewed at its risk class like any other code;
#   * CI workflow + action definitions — the `[skip ci]` / job-wiring surface;
#   * `extensions/**` — every local enforcement gate (review-enforcer,
#     verification-gate, sequence-enforcer);
#   * `skills/**` and `templates/**` — AGENT-EXECUTABLE INSTRUCTIONS. `skills/`
#     is the script an enforcement gate runs (a micro edit to
#     `skills/code-review/SKILL.md` would rewrite what "reviewed" means, with no
#     reviewer dispatched) and `templates/` materializes into every consumer
#     repo's `AGENTS.md`. `clean_low_path_ok` already refuses to call this layer
#     prose (it excludes root instruction files and any enforcement input); the
#     cap must not be laxer than the class beneath it;
#   * `enforcement/**` — the dangerous-ops manifest the skill enforcer reads.
# Exact basenames under `scripts/` plus directory prefixes elsewhere: bash `case`
# globs cross `/`, which is why the script files are enumerated EXACTLY rather
# than as `scripts/*.sh` (that would put every script in the always-full class
# and the cap would never fire).
review_full_surface_path() { # <path> → rc0 = ALWAYS-FULL, rc1 = not, rc2 = unclassifiable
  local p="$1"
  [ -n "$p" ] || return 2
  # Path hygiene first: a raw control character, an absolute path, a `~` path or
  # a `.`/`..`/empty segment must never be CLASSIFIED here (a `docs/../scripts/…`
  # would otherwise evade every arm below). Same posture as clean_low_path_ok,
  # and the caller treats an unclassifiable path as full — so a malformed row
  # can never certify a SHALLOWER tier.
  case "$p" in
    *[$'\n\r\t']*) return 2 ;;
  esac
  case "$p" in
    /*|~*) return 2 ;;
  esac
  case "/$p/" in
    *"//"*|*"/./"*|*"/../"*) return 2 ;;
  esac
  case "$p" in
    scripts/admin-merge.sh|scripts/ci-failure-set.sh|scripts/atomic-land.sh|scripts/check-pipeline-compliance.sh|scripts/record-review.sh|scripts/lib/diff-normalize.py) return 0 ;;
    # Rail-exec'd decision modules: `admin-merge.sh` execs BOTH of these to decide
    # whether a red check blocks — `ci_exemption.py` makes the exemption call and
    # `ci-workflow-pr-evaluable.sh` decides that such a red must stay BLOCKING.
    # Matched by EXACT name, not by the `check-` shape: a defect here makes a
    # genuinely failing check read as exempt, which is the false PASS this class
    # exists to prevent.
    scripts/ci_exemption.py|scripts/ci-workflow-pr-evaluable.sh|scripts/checkout_guard.sh|scripts/ci_runner_gate.sh) return 0 ;;
    scripts/check-*|.github/workflows/*|.github/actions/*|.husky/*|extensions/*|skills/*|enforcement/*|templates/*) return 0 ;;
  esac
  return 1
}

# review_tier_cap — rows ("<status>\t<path>\t<old>") on stdin → echoes the
# HIGHEST verdict tier the diff's surfaces justify: `full`, `low` or `micro`.
#   full  — a path in the ALWAYS-FULL class is touched: neither clean-micro nor
#           clean-low may be claimed; only `clean` is honest.
#   low   — every path is in the clean-low content class: `clean-low` is honest
#           (and `clean` stays permitted — a stronger claim is never false).
#   micro — neither of the above: the micro EXEMPTION is the only one available,
#           and it is further conditioned on the linked issue's label by the
#           clean-micro guard below.
# rc 1 (no rows) is a FAIL-CLOSED signal for callers: an empty diff has no
# surface to certify.
review_tier_cap() {
  local paths p seen=0 rc=0
  paths="$(LC_ALL=C awk -F '\t' 'NF >= 2 && $2 != "" { print $2; if ($3 != "") print $3 }' | LC_ALL=C sort -u)"
  [ -n "$paths" ] || return 1
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    seen=1
    # 0 = always-full, 2 = UNCLASSIFIABLE — both leave the diff with no claim to
    # a shallower tier. Only 1 (classifiable, not full) may continue. Captured in
    # `rc` rather than read from `$?` inside an `elif`, so the arm is explicit
    # and cannot inherit an unrelated last-command status.
    rc=0
    review_full_surface_path "$p" || rc=$?
    if [ "$rc" -eq 0 ] || [ "$rc" -eq 2 ]; then
      printf 'full\n'; return 0
    fi
  done <<< "$paths"
  [ "$seen" -eq 1 ] || return 1
  while IFS= read -r p; do
    [ -z "$p" ] && continue
    if ! clean_low_path_ok "$p"; then
      printf 'micro\n'
      return 0
    fi
  done <<< "$paths"
  printf 'low\n'
  return 0
}

# review_surface_rows <repo> <pr> <sha> — print the changed-file rows of
# compare/<base>...<sha>, prefixed by one "mb\t<merge-base>\t<expected-count>"
# line.
#   rc 0 = rows printed (header + at least one row)
#   rc 1 = TRANSPORT failure with nothing read — gh absent, the `pulls` read
#          failed, or the compare failed for a reason that is NOT a refusal of
#          this revision (403 rate-limit, 5xx, no route to host). Absent
#          evidence; the callers warn loudly and proceed.
#   rc 2 = the API answered: the PR has NO changed files.
#   rc 3 = the API ANSWERED and REFUSED, or answered with a payload this
#          classifier cannot certify: a `pulls` body with no base/count, a
#          compare HTTP 404/422 (a fork head, a rewritten sha), a compare that
#          exited 0 with no readable body, no merge base, no rows, a malformed
#          row. POSITIVE evidence, so the callers REFUSE. It must never be
#          confused with rc 1: that confusion was how one `copied` row, and
#          separately a fork-head 404, turned the cap into a no-op and let a
#          rail edit record `clean-micro`.
#
# An EXPLICIT <sha>, not pulls/<n>/files, for the reason the clean-low guard
# gives above: pulls/<n>/files always describes the CURRENT head, so a push
# landing between the read and the write would let one revision be certified
# while another merges. A compare against an explicit sha has no such window.
review_surface_rows() {
  local repo="$1" pr="$2" sha="$3" meta head base count cmp mb first rest
  command -v gh >/dev/null 2>&1 || return 1
  meta="$(command gh api "repos/$repo/pulls/$pr" --jq '[(.head.sha), (.base.sha), ((.changed_files // 0) | tostring)] | @tsv' 2>/dev/null)" || return 1
  head="$(printf '%s' "$meta" | cut -f1)"
  base="$(printf '%s' "$meta" | cut -f2)"
  count="$(printf '%s' "$meta" | cut -f3)"
  [[ "$base" =~ ^[0-9a-f]{40}$ ]] || return 3
  [[ "$count" =~ ^[0-9]+$ ]] || return 3
  # Zero changed files is the `empty` status, not a truncation and not a tier.
  [ "$count" -gt 0 ] || return 2
  # An empty <sha> means "the PR's current head" (the --print-tier selector).
  # Every recording caller passes an explicit sha (see the header note above).
  if [ -z "$sha" ]; then
    [[ "$head" =~ ^[0-9a-f]{40}$ ]] || return 3
    sha="$head"
  fi
  # A non-2xx here is NOT transport. The pulls read SUCCEEDED, so the API is
  # reachable and answered our first question; it REFUSED the second, which means
  # this revision cannot be compared (the fork-head / unreachable-sha 404 this
  # codebase documents as predictable, or a rewritten sha). That is POSITIVE
  # evidence, so rc 3 — refusing — not rc 1. Classifying it as transport made the
  # cap silently no-op on exactly the case the sibling clean-low guard hard-fails
  # 60 lines later, leaving a fork PR that edits a rail free to record
  # clean-micro (measured: rc 0, record written, one stderr line).
  # A compare failure is only POSITIVE evidence when the API REFUSED this
  # revision. `gh` exits 1 for a 404, a 403 rate-limit, a 502 and a dead socket
  # alike, so the exit code alone cannot carry that distinction — and getting it
  # wrong in either direction is a real cost:
  #   * treating a refusal as transport let a fork-head 404 (documented here as
  #     predictable) record clean-micro on a rail diff;
  #   * treating transport as a refusal would strand a legitimate micro PR on a
  #     rate-limit window or a blip, and tell it to go pay for a full review.
  # So classify on the STATUS gh reported: an HTTP refusal of THIS revision
  # (404 Not Found / 422 Unprocessable) is rc 3; everything else — 403, 5xx, no
  # route to host, empty stderr — is rc 1 (nothing read, warn and proceed), the
  # same posture the `pulls` read above already takes.
  CMP_ERR="$(mktemp 2>/dev/null)" || CMP_ERR=""
  if [ -n "$CMP_ERR" ]; then
    cmp="$(command gh api "repos/$repo/compare/$base...$sha" --jq '.merge_base_commit.sha as $mb | "mb\t\($mb)", (.files[]? | [.status, .filename, (.previous_filename // "")] | @tsv)' 2>"$CMP_ERR")"
  else
    cmp="$(command gh api "repos/$repo/compare/$base...$sha" --jq '.merge_base_commit.sha as $mb | "mb\t\($mb)", (.files[]? | [.status, .filename, (.previous_filename // "")] | @tsv)' 2>/dev/null)"
  fi
  if ! [[ "$cmp" =~ ^mb ]]; then
    CMP_REFUSED=0
    if [ -n "$CMP_ERR" ] && command grep -qE 'HTTP (404|422)\b' "$CMP_ERR" 2>/dev/null; then CMP_REFUSED=1; fi
    [ -n "$CMP_ERR" ] && rm -f "$CMP_ERR"
    [ "$CMP_REFUSED" -eq 1 ] || return 1
    return 3
  fi
  [ -n "$CMP_ERR" ] && rm -f "$CMP_ERR"
  # Split the header line in BASH, never `printf … | head -1 | cut`. This script
  # runs `set -o pipefail`, and a `head` that exits after its one line sends
  # SIGPIPE to the writer — the substitution then fails and, under `set -e`, the
  # whole script aborts with NO output at all. Measured on this seam: 9 of 40
  # identical runs produced empty stdout. The failure is SILENT (a caller reading
  # a status finds nothing), which is the #2412 class this repo spent a change
  # removing from lander.test.sh.
  first="${cmp%%$'\n'*}"
  if [[ "$cmp" == *$'\n'* ]]; then rest="${cmp#*$'\n'}"; else rest=""; fi
  IFS=$'\t' read -r _tag mb _tail <<< "$first"
  [[ "$mb" =~ ^[0-9a-f]{40}$ ]] || return 3
  [ -n "$rest" ] || return 3
  # FRAMING-AGNOSTIC validation: the cap only needs PATHS, so it must not inherit
  # the clean-low attestation's status enum (`clean_low_rows` deliberately
  # refuses `copied`, and reusing it here meant one unusual row discarded the
  # whole read and the record PROCEEDED). Any non-empty path is accepted; a row
  # with no path is rc 3, not silence.
  if ! LC_ALL=C awk -F '\t' 'NF < 2 || $2 == "" { exit 1 }' <<< "$rest"; then
    return 3
  fi
  printf 'mb\t%s\t%s\n' "$mb" "$count"
  printf '%s\n' "$rest"
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
verify_review_evidence() { # <ref> <head_sha> [polarity] -> 0 = verified
  # #3400 — POLARITY. The default (`clean`) is the original contract: the
  # artifact must NOT assert a non-clean outcome. `not-clean` inverts ONLY the
  # outcome assertions — the artifact is EXPECTED to declare the negative, since
  # that is what the verdict being recorded says happened. Every structural arm
  # below (recognisable ref, exists, belongs to THIS PR, postdates the head, is
  # not itself a record marker) is shared, so a negative record cannot be minted
  # over an artifact that is missing, foreign or older than the revision it
  # claims to describe.
  local ref="$1" head="$2" polarity="${3:-clean}" split kind id row created parent body state head_date _rest
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
  if [ "$polarity" != "not-clean" ] && [ -n "$state" ] && [[ ! "$state" =~ ^(APPROVED|COMMENTED)$ ]]; then
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
  #   "⚠️ Auto-fix reached this change's proportional cycle ceiling (N of B cycles, …)
  #       — blocking issues remain; escalate to a human"      (#1537, the class-keyed cap)
  #   "[PROPORTIONAL] cycles=… cap=… blocking=0 follow-ups=…"  (#1537 LANDING form — NOT vetoed:
  #       blocking=0 and the follow-ups are FILED issues, so the review concluded clean; the
  #       escalation form above shares the label and is vetoed by its own text)
  #   "⚠️ Test review capped at 10 cycles — N issues remain:"   (literal N)
  #   "Requires Human Input / Requires Human Attention"        (plan-review block)
  #   "[ADVERSARIAL-BOUND] cycles=… threats=… covered=… residuals=…"
  #   "[NO-LOOP-BUDGET] RISK_CLASS=low — the single Step 4 pass is the whole budget…"
  #       (#1537: a `low` change budgets NO re-review loop, so entering the loop means
  #       findings survived Step 6. Naming that comment as `clean` evidence would mint a
  #       clean verdict over un-re-reviewed findings — it is vetoed, unlike the landing
  #       form `[PROPORTIONAL] … blocking=0 follow-ups=…`, whose follow-ups are FILED)
  # Every prefix above is quoted from `skills/code-review/references/fixer-loop.md
  # §"PR comment prefix"` — the file that OWNS the vocabulary — because an earlier
  # revision of this arm hard-coded a PARAPHRASE ("human attention") of the skill's
  # actual marker ("requires human review") and therefore admitted four of the
  # seven unresolved prefixes verbatim, reproducing the tortoise#3549 shape:
  # a lane whose review ABORTED could name its own Step-8 comment and mint clean.
  # An unresolved-exit prefix that this list does not name is a fail-open, so
  # extend it from fixer-loop.md, never from memory.
  # ⛔ THREE ARMS, AND THE SPLIT IS SECURITY-RELEVANT (1b below is unconditional too).
  #
  # (1) STRUCTURAL ABORT MARKERS — always veto, unconditionally. These are the review skills' own
  #     Step-8 exit prefixes (fixer-loop.md §"PR comment prefix"). A lane whose review ABORTED emits
  #     one of them, so vetoing them unconditionally is what keeps the tortoise#3549 hole closed: a
  #     lane cannot mint `clean` by naming its own aborted Step-8 comment, whether or not that
  #     comment also claims an outcome.
  #
  # (2) THE LOOSE `not…clean` ARM — only when the artifact states NO explicit outcome. It is a
  #     substring search over prose, and prose about code reviews legitimately contains the phrase
  #     mid-sentence, while a review of fail-closed code necessarily uses words like "failed" and
  #     "unresolved". Measured 2026-10-17 (agent-infra#1964) on tortoise#8866: a genuine CLEAN review
  #     whose body opens `**Outcome: CLEAN — no blocking issues found.**` was REFUSED (rc=3) because
  #     a later sentence contained that phrase, parking a reviewed PR with a false "evidence could
  #     not be verified" diagnosis.
  #
  #     So when the artifact states an explicit `Outcome:` field, that field IS its claim about the
  #     outcome and arm (2) is skipped; arm (1) still applies. Without an `Outcome:` field nothing
  #     changes — the loose arm runs exactly as before, so this cannot widen the fail-open.
  # ⛔ #3400 — A `not-clean` VERDICT SKIPS THE OUTCOME ARMS, AND ONLY THOSE.
  # Arms (1)/(1b)/(2) below ask "does this artifact say the review did NOT conclude
  # clean?" and refuse a CLEAN mint when it does. For a not-clean mint that is the
  # WRONG question: an artifact declaring the negative is exactly the evidence an
  # honest negative verdict has, and vetoing it would leave a lane able to record
  # "NOT CLEAN" only by naming an artifact that never mentions the finding. Every
  # STRUCTURAL arm above has already run — that is the part that stops an unfounded
  # record — so nothing is weakened here: a clean mint still runs every arm below,
  # unchanged and unconditional. (This is also why the veto cannot be reached by a
  # caller who did not ask for it: polarity comes from the VERDICT, not a flag.)
  if [ "$polarity" = "not-clean" ]; then
    printf '%s %s on %s#%s, created %s, postdates head %s (NEGATIVE-polarity evidence: the artifact is expected to declare the not-clean outcome, so arms 1/1b/2 do not apply)\n' \
      "$kind" "$id" "$REPO" "$PR" "$created" "${head:0:12}"
    return 0
  fi
  if grep -qiE 'auto-fix[[:space:]]+(stalled|failed|reached|aborted|converged|stuck)|require[s]?[[:space:]]+human[[:space:]]+(attention|input|review)|unresolved[[:space:]]+issues?|[0-9]+[[:space:]]+issues?[[:space:]]+remain|test[[:space:]]+review[[:space:]]+capped|\[ADVERSARIAL-BOUND\]|\[NO-LOOP-BUDGET\]' <<<"$body"; then
    echo "   $kind $id asserts an UNRESOLVED outcome (a stalled/failed/cap/human-input exit) — it is evidence the review did not conclude clean." >&2
    return 1
  fi
  # (1b) DECLARED NEGATIVE OUTCOMES — always veto, and BEFORE the `Outcome:` suppression. Without
  #      this arm the suppression hands back the tortoise#3549 shape (§13f) for the price of one
  #      pasted line: a body that declares BOTH a clean outcome and a NOT-CLEAN outcome was accepted
  #      (found in review of this change, both orderings reproduced). It vetoes DECLARATIONS only —
  #      an `Outcome: not clean` line, or a `Review — NOT CLEAN` header — so prose that merely
  #      discusses cleanliness (the tortoise#8866 false refusal this change exists to fix) still
  #      passes. Arm 2 is the only arm the `Outcome: clean` field may suppress.
  if grep -qiE '(^|[*[:space:]])outcome:[[:space:]]*[*[:space:]]*(not|non|no)[[:space:]_-]*clean|(^|[[:space:]>*-])review[[:space:]]*[—–-][[:space:]]*not[[:space:]_-]*clean' <<<"$body"; then
    echo "   $kind $id DECLARES a non-clean outcome (an explicit Outcome: not-clean, or a 'Review — NOT CLEAN' header) — it is evidence the review did not conclude clean." >&2
    return 1
  fi
  if ! grep -qiE '(^|[*[:space:]])outcome:[[:space:]]*(clean|\*\*clean)' <<<"$body"; then
    if grep -qiE 'not[[:space:]_-]*clean' <<<"$body"; then
      echo "   $kind $id asserts an UNRESOLVED outcome (NOT-CLEAN, and states no explicit Outcome:) — it is evidence the review did not conclude clean." >&2
      return 1
    fi
  fi
  printf '%s %s on %s#%s, created %s, postdates head %s\n' "$kind" "$id" "$REPO" "$PR" "$created" "${head:0:12}"
  return 0
}

# ── #1709 rec 7 — the record's IDENTITY, for idempotent same-head writes ──
# `record-review.sh` runs at-least-once (a duplicate execution is possible under
# crashes, pauses and cross-box dispatch), so its side effects must be idempotent:
# running it twice for the SAME head must produce the SAME artifact, not a second
# one. The PR-body MARKER already satisfies this — it is a function of
# (pr, verdict, sha, diff, repo) and the append is guarded by a whole-string
# `grep -qF` — but the RECORD FILE did not: every run re-stamped `reviewed_at`
# from the wall clock and rewrote the file, so a duplicate execution MUTATED the
# attestation. That is corruption, not waste: `reviewed_at` is the audit trail's
# only join from a merge-gate pass to the review dispatch that authorised it
# (extensions/review-enforcer logMergeGateDecision), and the mint time of a
# reviewed head must not move because a paused worker resumed.
#
# The idempotency KEY is the head sha — the same content-addressing #1709 rec 1
# applies to claims. Two records are the SAME attestation when their deterministic
# identity matches: pr, head_sha, the diff/merge-base bindings, the evidence ref,
# the verdict and the repo. The VOLATILE fields — `reviewed_at`, and the carry
# provenance (`mint`, `carried_from`, `carried_at`) — are NOT identity: they are
# what the duplicate would churn, and stripping them from BOTH sides lets a
# carry and a fresh mint at the same head compare equal (a duplicate of either
# is a no-op, which is exactly right: the head is already recorded).
#
# This is deliberately EXACT-string comparison over the canonicalized single-line
# JSON, not a jq/python parse: the record is written by ONE printf with a fixed
# field order, and a second parser here would be a second definition of the
# record's shape. A malformed or foreign file simply fails to match, and the
# write proceeds as before (fail-open on the GUARD, never on a safety property —
# this only decides whether to rewrite an already-correct file).
record_identity() { # <record-file> -> the record with its volatile fields removed
  sed -E \
    -e 's/,"reviewed_at":"[^"]*"//' \
    -e 's/"mint":"[^"]*",//' \
    -e 's/"carried_from":"[^"]*",//' \
    -e 's/"carried_at":"[^"]*",//' \
    "$1"
}

# ── BODY-MARKER DURABILITY (defect A) ─────────────────────────────────────
# A signed marker is what CI can read — in the PR body, or in an admitted PR
# COMMENT (records are per-box), so a record whose marker reached NEITHER is a
# record nobody can see — and the old behaviour (warn + exit 0) made that state
# indistinguishable from success, which is how a reviewed PR sat blocked with
# "No AI review evidence found" while the script reported it was fine.
#
# The contract here:
#   * the marker is written to a PENDING file BEFORE the post is attempted, so
#     the bytes that must be delivered survive a failed POST, a killed shell or
#     a 403 window (the measured cause: the shared 5000/hr token exhausted);
#   * a failed delivery is a NAMED non-zero state (`body-marker-unposted`, exit
#     5), never a warning on a zero exit;
#   * `--flush-pending` delivers a pending marker later, WITHOUT re-recording and
#     WITHOUT a new review — the verdict was already minted and verified.
# The pending file holds exactly the marker LINE, so recovering it can never
# mint a different claim than the record it belongs to.
marker_pending_dir() { printf '%s' "$HOME/.pi/agent/reviews/pending"; }
marker_pending_file() { # <repo-or-empty> <pr>
  # ⛔ CANONICAL AND UNAMBIGUOUS (fresh-review cycle 3). Two lossy properties of the
  # first spelling, both measured by a reviewer: owner/repo are CASE-INSENSITIVE on
  # GitHub, so a re-run naming `Daniel-Ospina/agent-infra` looked up a different
  # filename and answered "nothing pending" (exit 0) over a stranded marker; and the
  # `<owner>-<repo>` join collided, so `a-b/c#42` and `a/b-c#42` shared one file.
  # Lowercased, with a `__` separator that neither half can contain.
  if [ -n "${1:-}" ]; then
    printf '%s/%s__%s-%s.marker' "$(marker_pending_dir)" \
      "$(printf '%s' "${1%/*}" | tr '[:upper:]' '[:lower:]')" \
      "$(printf '%s' "${1#*/}" | tr '[:upper:]' '[:lower:]')" "$2"
  else
    printf '%s/legacy-%s.marker' "$(marker_pending_dir)" "$2"
  fi
}
marker_pending_write() { # <file> <marker-line> -> 0 written
  local f="$1"
  command mkdir -p "$(marker_pending_dir)" 2>/dev/null || return 1
  printf '%s\n' "$2" > "${f}.$$.tmp" 2>/dev/null || return 1
  command mv -f "${f}.$$.tmp" "$f" 2>/dev/null || return 1
  return 0
}
# post_marker <repo> <pr> <marker-line> -> 0 = the marker is IN the body now.
# Idempotent (a body already carrying it is success) and it never clobbers the
# description: the existing body is read first, and an unreadable body is a
# FAILURE (2), not an empty body to overwrite.
post_marker() { # <repo> <pr> <marker> -> 0 present/posted, 1 post failed, 2 body unreadable
  local repo="$1" pr="$2" marker="$3" body="" newbody=""
  body="$(command gh api "repos/$repo/pulls/$pr" --jq .body 2>/dev/null)" || return 2
  [ "$body" = "null" ] && body=""
  # ⛔ LINE-ANCHORED (`-x`), the SAME predicate the recorder's append decision uses
  # (agent-infra#3168). This site is the RECOVERY path — reached by `--flush-pending`
  # and by every later minting run — and it is the one that can DESTROY the marker:
  # unanchored `-qF` read a body that merely CITES the marker mid-line as "already
  # present", so it PATCHed nothing, flush_pending_markers() `rm -f`'d the pending
  # file, and the caller printed "delivered the pending signed marker" (the wording
  # before #3168 — see the success line below, which now claims no signedness). Silent loss
  # of the only copy of those bytes, reported as success (a false PASS).
  # ⛔ The here-string is also what makes the SIGPIPE class impossible here (#841/#864,
  # the idiom scripts/check-no-sigpipe-grep.sh guards): `grep -q` exits at the first
  # match, so a `producer | grep -q` pipeline over a body larger than the pipe buffer
  # takes SIGPIPE and `pipefail` reports the pipeline FAILED — reading a marker that IS
  # present as absent and re-patching a body that already carries it. A here-string is
  # bash 3.2-safe and has no producer process to signal. Both intents are load-bearing
  # at this one site, which is why the fix carries both.
  if command grep -qxF -- "$marker" <<<"$body"; then return 0; fi
  if [ -n "$body" ]; then newbody="${body}

${marker}"; else newbody="$marker"; fi
  if command jq -n --arg body "$newbody" '{body: $body}' 2>/dev/null \
      | command gh api -X PATCH "repos/$repo/pulls/$pr" --input - >/dev/null 2>&1; then
    return 0
  fi
  return 1
}
# post_marker_comment <repo> <pr> <marker> -> ALWAYS 0 (best-effort, never fatal)
#
# agent-infra#1224, PRODUCER HALF — the consumer half shipped in the gate in 2026-09,
# and docs/ai-review-gate.md carried "Producer status: the producer half is NOT
# deployed" for a month. Everything below is why this is not optional, and it lives
# at the FUNCTION because every caller (the mint path, both failure arms,
# --flush-pending and --recover-body) must publish the same channel with the same
# guarantees:
#
# ── Durable channel: the SAME signed marker as an append-only PR COMMENT ──
# The PR body is a MUTABLE field that lanes rewrite routinely, so a body-only
# marker is one edit away from being no marker at all, and the edit that removed
# it is invisible — the next read reports "No AI review evidence found" for a
# review that genuinely happened. Measured 2026-10-31: tortoise#10410 carries a
# signed clean marker at its exact head d96ffe8c, its only gate attempt was
# created BEFORE that marker landed and concluded `failure` with "No AI review
# evidence found in PR #10410 body or comments", and the head then held that red
# with the verdict present. tortoise#10424's own review comment reports the same
# shape (a `reviews/10424.json ... clean @ 3805f492` attestation that no longer
# covers the head it sits on, after a body edit).
# The gate already unions body ∪ comments and HMAC-verifies both, admitting only
# OWNER/MEMBER/COLLABORATOR comments, so this ADDS AVAILABILITY and changes no
# security property: a forged or stale comment still fails the HMAC or the
# binding rules. Idempotent — post only when no admitted comment already carries
# this exact marker text. Best-effort: NEVER fails the record.
# ⛔ THE BODY MIRROR STAYS, AT *BOTH* SITES — this function only ADDS a copy.
# (1) `post_marker()`, immediately ABOVE this comment: the recovery half
# (--flush-pending, and any later minting run) PATCHes the marker into the PR body
# there. (2) The MINT path further DOWN this file, which is the run that actually
# mints the record. EITHER site's PATCH is what fires `edited` and re-runs the
# gate; a comment alone fires `issue_comment`, which this gate deliberately does
# not trigger on (see the skip-footgun rule in the workflow header). An earlier
# draft of this block had been moved here from the old inline site but stayed
# indented two spaces, so it read as function body and named only "the body mirror
# above" — which is true of ONE of the two sites. Same information, one copy, at
# the indentation this doc comment actually uses.
post_marker_comment() { # <repo> <pr> <marker>
  local repo="$1" pr="$2" marker="$3"
  local PR_EVIDENCE_COMMENTS_JQ="" HAVE_COMMENT=0 EXISTING_COMMENT_BODIES=""
  local _mtext="" _msig="" _mexp=""
  # ⛔ AN UNSIGNED MARKER IS NEVER PUBLISHED AS A COMMENT. The gate can never accept
  # one (it HMAC-verifies), and unlike the body a comment is PERMANENT. Enforced HERE,
  # at the single chokepoint, so no caller can forget it and no new call site can
  # reopen the hole. The unsigned path stays body-only, where its warning is loud.
  # ⛔ THIS GUARD MUST VERIFY THE HMAC — A TEXT MATCH IS NOT ENOUGH (#3168 re-review
  # finding 1, exploited at runtime). The first version of this guard tested
  # `case "$marker" in *" sig="*)`, i.e. it decided "signed" from a SUBSTRING of the
  # marker. That is forgeable from an ordinary CLI flag: `--findings-note` is
  # free-form (rejected only for `"`, `\` and control chars, :1667) and is spliced
  # into the marker verbatim (:4819), so a key-less not-clean mint with
  # `--findings-note 'quoted sig=<64hex>'` produced a marker containing ' sig=',
  # passed the guard, and POSTED itself permanently — measured: 1 POST against a
  # stub `gh` for an unsigned marker, while the same probe on a CLEAN unsigned
  # marker correctly made 0. Trailer-anchoring (` sig=[0-9a-f]{64}$`) does NOT close
  # it either, for the same reason (`note=x sig=<64hex>` ends the marker that way).
  # `MARKER_SIGNED` is not the fix either: it is assigned only in the MINT path (below
  # :4826), so a call site that asks for a marker first — flush_pending_markers (:1744)
  # and --recover-body (:2898) — cannot see it, whatever the GATE_KEY's scope is.
  # So apply the file's OWN doctrine (:2886): "a marker is EVIDENCE only when
  # its `sig=` verifies over its own text". The key is resolved GLOBALLY at :2870,
  # but ⛔ that is NOT above every call site — so this function must never assume
  # the global is in scope. Split on the LAST ' sig=' — that is the real trailer,
  # and it also keeps a note that legitimately contains ' sig=' working, because
  # the genuine signature is appended after it. Any failure ⇒ no comment (fail closed).
  # ⛔ `${GATE_KEY:-}`, NOT `$GATE_KEY` (#3168 re-review): `--flush-pending`
  # dispatches at :1744, BEFORE the global assignment at :2870, so under `set -u`
  # a bare `$GATE_KEY` here aborts the whole flush (measured: 11 assertions red,
  # "line 1239: GATE_KEY: unbound variable"). An unset key must read as
  # "unsigned" and fail CLOSED, never as a crash.
  case "$marker" in
    *" sig="*) ;;
    *) return 0 ;;
  esac
  _mtext="${marker% sig=*}"
  _msig="${marker##* sig=}"
  [[ "$_msig" =~ ^[0-9a-f]{64}$ ]] || return 0
  # ⛔ RESOLVE THE KEY LOCALLY WHEN THE CALLER'S SCOPE PREDATES THE GLOBAL. The
  # global is assigned at :2870, but `--flush-pending` dispatches at :1744 — long
  # before it — so a bare `$GATE_KEY` here was an `unbound variable` abort under
  # `set -u` in the flush (measured: 11 assertions red, line 1239), and taking the
  # global's EMPTY value instead would silently fail CLOSED on a good signed
  # marker, disabling the durable copy on the one path whose entire purpose is to
  # deliver it. Replicating the same resolution keeps this function authoritative
  # at every call site without moving a global the mint path deliberately
  # resolves once, above the stale-sha guard.
  local _key="${GATE_KEY:-}"
  if [ -z "$_key" ]; then
    _key="${AI_REVIEW_GATE_KEY:-}"
    [ -n "$_key" ] || _key="$(cat "$HOME/.pi/agent/.ai-review-gate-key" 2>/dev/null || true)"
    _key="$(printf '%s' "$_key" | tr -d '[:space:]')"
  fi
  [ -n "$_key" ] || return 0
  _mexp="$(printf '%s' "$_mtext" | command openssl dgst -sha256 -hmac "$_key" 2>/dev/null | awk '{print $NF}' || true)"
  [ -n "$_mexp" ] || return 0
  if [ "$_mexp" != "$_msig" ]; then
    # LOUD, because this arm means the caller believed it had a signed marker and
    # did not — either a tampered/corrupt marker or a key that no longer matches
    # the one that signed it. Either way the durable copy is REFUSED, not degraded.
    echo "⚠️ record-review: REFUSING to publish a marker to the durable comment channel — its \`sig=\` does not verify against the configured AI_REVIEW_GATE_KEY. An unverifiable marker must never become a permanent PR comment (the gate could never accept it, and unlike the PR body it cannot be retracted). No comment was posted." >&2
    return 0
  fi
  # BYTE-IDENTICAL to the gate's PR_EVIDENCE_COMMENTS_JQ
  # (.github/workflows/ai-review-gate.yml, the #1224 cross-repo contract).
  # ⛔ DECLARED RESIDUALS OF THIS CONSTANT — the gate's contract asks a producer to
  # declare them AT THE CONSTANT (ai-review-gate.yml :86-87, :421-424), so they live here:
  #   1. AUTHOR SET. A recording identity whose comment reports
  #      `author_association` outside {OWNER, MEMBER, COLLABORATOR} (a GitHub-App
  #      or bot token) is INVISIBLE to its own dedup read and to the gate → one
  #      duplicate comment per run, and no comment-borne evidence admitted. It
  #      degrades to the pre-change behaviour (the body mirror still carries the
  #      verdict), so the record is never lost. Unarmed here: `gh` is repo-OWNER.
  #   2. READ-FAILURE ARM. When the comment read FAILS (HAVE_COMMENT=-1) the
  #      durable post is SKIPPED for that call BY DESIGN — an error body printed
  #      to STDOUT must never be read as comment text. Whether a BODY copy exists
  #      is reported by the CALLER, never here: FOUR of the five call sites reach
  #      this function with no body copy saved (see the success line below).
  #   3. VERDICT TIERS. `marker_re` admits only `verdict=clean(-micro|-low)?` (tortoise
  #      ai-review-gate.yml:612), so a published `not-clean` marker is a durable copy of a
  #      NEGATIVE verdict the GATE does not admit — it adds no gate availability at all.
  PR_EVIDENCE_COMMENTS_JQ='.[] | select(.author_association == "OWNER" or .author_association == "MEMBER" or .author_association == "COLLABORATOR") | .body'
  HAVE_COMMENT=0
  if EXISTING_COMMENT_BODIES="$(command gh api --paginate \
       "repos/$repo/issues/$pr/comments" --jq "$PR_EVIDENCE_COMMENTS_JQ" 2>/dev/null)"; then
    if grep -qxF -- "$marker" <<<"$EXISTING_COMMENT_BODIES"; then
      HAVE_COMMENT=1
    fi
  else
    # Fail SOFT here but LOUDLY, and do not conflate this with "no comment
    # exists": `gh api` prints HTTP error bodies to STDOUT, so an unguarded
    # capture would read an error body as comment text and could then believe
    # the marker is already posted when it is not.
    # ⛔ NO CLAIM ABOUT THE BODY CHANNEL (#3168 fresh-review finding): this warning is
    # emitted from EVERY arm that calls this function, and two of them (the body-READ
    # failure and the body-PATCH failure) reach it with no body copy at all — so the
    # old tail, "the body copy above is unaffected", was FALSE at exactly the arms an
    # operator most needs to trust. Each caller reports its own body-channel outcome;
    # this line reports ONLY what this function knows, same rule as the success line.
    # ⛔ IT MUST NOT PROMISE A RETRY, AND IT MUST NOT NAME A CAUSE (#3168 review).
    # Both were false here. The read's error text is discarded (2>/dev/null on the
    # capture — deliberately, so an HTTP error body can never be read as comment
    # text), so "transient API failure" was a guess that also covered a permanent
    # 404. And "re-run this to retry" is FALSE at two of the five call sites:
    # flush_pending_markers deletes its pending marker once its body post succeeds,
    # and --recover-body refuses outright once a record exists — at both, the verb
    # that printed this line cannot retry the durable copy at all. The remedy is
    # the CALLER's to state; this function reports only what it observed.
    echo "⚠️ record-review: could not read the PR's comments on $repo#$pr — this call created no durable comment copy, and this line makes no claim about the body channel. It does not name a CAUSE either (the read's error text is discarded by design), and ⛔ it deliberately promises NO retry: whether re-running helps is the CALLER's business, and at flush_pending_markers and --recover-body it does not, because those two verbs cannot reach this call a second time. Read the calling verb's own message for the remedy it can honour." >&2
    HAVE_COMMENT=-1
  fi
  if [ "$HAVE_COMMENT" = "0" ]; then
    if command jq -Rn --arg body "$marker" '{body: $body}' 2>/dev/null \
        | command gh api -X POST "repos/$repo/issues/$pr/comments" --input - >/dev/null 2>&1; then
      # ⛔ THIS FUNCTION CANNOT ASSERT THE BODY MIRROR'S STATE (#3168 fresh-review
      # findings 1+2). It has FIVE call sites (flush_pending_markers, --recover-body,
      # the body-READ-failure arm, the body-PATCH-failure arm, and the mint path), and
      # FOUR of them reach this line in a state where the body copy is NOT saved:
      # --recover-body never posts a body at all, --flush-pending runs this function
      # BEFORE its own body post, and both failure arms reach it having failed the
      # body channel. Only the mint path has the body saved. Both failure arms print
      # their own body-channel message on the line above, so an assertion about the
      # body here contradicted them during exactly the 403 / spent-token window an
      # operator is debugging. Each caller already reports its
      # own body-channel outcome; this line reports ONLY what this function knows.
      echo "review evidence posted to $repo#$pr as a durable comment"
    else
      echo "note: could not post the durable comment copy of the review evidence" >&2
    fi
  fi
  return 0
}

# flush_pending_markers <repo-or-empty> <pr> -> 0 all delivered (or none
# pending), 1 still undelivered. NEVER mints: it only re-delivers bytes a
# previous run already recorded, so it cannot outrun the review it came from.
flush_pending_markers() { # <repo-or-empty> <pr>
  local repo="${1:-}" pr="$2" f="" marker=""
  f="$(marker_pending_file "$repo" "$pr")"
  [ -f "$f" ] || return 0
  [ -n "$repo" ] || return 1          # no repo ⇒ no PR body to deliver to
  command -v gh >/dev/null 2>&1 || return 1
  marker="$(command cat "$f" 2>/dev/null || true)"
  # AN EMPTY PENDING FILE IS NOT A DELIVERED MARKER (fresh-review P1). This used to
  # `rm -f` and return 0, so the flush printed "delivered" over a file that held no
  # bytes and then DELETED it — defect A's own shape inside its fix, destroying the
  # only copy. Report the corruption and KEEP the file.
  if [ -z "$marker" ]; then
    echo "body-marker-unposted: the pending marker file for $repo#$pr is EMPTY ($f) — there are no bytes to deliver, and nothing was posted or deleted. A record was written whose marker was never built; re-run the recorder at the same head WITH gh available to rebuild and post it." >&2
    return 1
  fi
  # agent-infra#1224/#3168: attempt the DURABLE copy FIRST, before the body decision.
  # The flush exists to recover a marker whose body channel failed — so the run that
  # cannot reach the body is exactly the run that must still leave an admitted
  # channel copy. Placed before post_marker() so a body-side failure cannot
  # short-circuit it; post_marker_comment() is best-effort and always returns 0.
  post_marker_comment "$repo" "$pr" "$marker" || true
  if post_marker "$repo" "$pr" "$marker"; then
    command rm -f "$f"
    return 0
  fi
  return 1
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
# tortoise#9492 — the reviewer's own statement of WHICH head they reviewed.
# Empty = legacy behaviour (the stale-sha guard + carry arms decide).
EXPECT_HEAD=""
# #1351 — set by --print-diff-hash (read-only consumer seam, see the header).
# Initialised here so `set -u` is satisfied when the flag is absent.
PRINT_DIFF_HASH=0
# #1351 — the LANE's question, answered: "my record's head is stale; is the DIFF I
# reviewed still the diff that would merge?" Set by --check-carry (read-only).
CHECK_CARRY=0
# #3315 — the recorded pair a caller names EXPLICITLY for --check-carry, so the
# carry predicate is answerable on a box (a CI runner) that has no record file.
# Empty = read this box's record, exactly as before.
RECORDED_DIFF=""
RECORDED_HEAD=""
# Set by --print-tier: the READ-ONLY surface-cap selector (see the header).
PRINT_TIER=0
# #2872 — rebuild a missing record from the PR body's SIGNED marker. Mints, so it
# is its own verb: `--check-carry` answers, `--recover-body` writes.
RECOVER_BODY=0
# ── BODY-MARKER DURABILITY (defect A, measured 2026-11-03 on tortoise#10677) ──
# A record whose SIGNED body marker never reached the PR is INVISIBLE to the
# required check: the per-box file under ~/.pi/agent/reviews is not a surface CI
# can read, so `ai-review-gate` correctly reports "No AI review evidence found"
# and a properly reviewed PR is blocked by a bookkeeping failure. The recorder
# used to print "record still saved" and exit 0 in that state, so nothing
# anywhere recorded that the evidence was missing and no later run could post it
# without paying for the review again. `--flush-pending` posts the marker a
# previous run minted but could not deliver; it mints nothing.
FLUSH_PENDING=0
# #10583 — re-attest the DELTA: re-bind a CLEAN record's own verdict to the live
# head ONLY when the authored diff is provably unchanged. A minting verb, so it
# takes <pr> [owner/repo] and NO head (the record names the reviewed head — that
# is the whole point: a lane that had to remember the old head could not use it).
DELTA=0
DELTA_FROM=""
# #3247 review (P1) — the head the DECIDING ARM actually measured, which is NOT always
# DELTA_FROM: only `lane` measures from the record's head. Written into the record as
# `delta.from`, so the pair a reader checks is the pair the proof covers.
DELTA_MEASURED_FROM=""
EVIDENCE=""
# agent-infra#3400 — the NEGATIVE verdict's finding count. Required for
# `not-clean` (so the gate can name WHAT is open, not merely that something is),
# refused for every other verdict (a flag that cannot affect the record must not
# be accepted, or the caller believes it wrote something it did not).
FINDINGS=""
FINDINGS_NOTE=""
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
    --print-diff-hash) PRINT_DIFF_HASH=1 ;;
    --check-carry) CHECK_CARRY=1 ;;
    --recorded-diff)
      # #3315 — the recorded `diff_sha256`, as carried in the PR body's marker.
      _i=$((_i + 1))
      if [ "$_i" -ge "${#_argv[@]}" ]; then
        echo "record-review.sh: --recorded-diff needs a value (the 64-hex diff_sha256 the record carries) — usage: record-review.sh --check-carry <pr> [owner/repo] [--recorded-diff <64hex> [--recorded-head <40hex>]]" >&2
        exit 2
      fi
      RECORDED_DIFF="${_argv[$_i]}"
      if ! [[ "$RECORDED_DIFF" =~ ^[0-9a-f]{64}$ ]]; then
        echo "record-review.sh: --recorded-diff expects a full lowercase 64-hex digest (got '$RECORDED_DIFF') — a short or upper-cased value could only be compared by a rule this mode does not implement, and accepting one would silently weaken the content-identity test." >&2
        exit 2
      fi ;;
    --recorded-head)
      # #3315 — the recorded head sha, so a REBASE is diagnosable as
      # `carry-patch` (re-record, no review) instead of `fresh` (review owed).
      _i=$((_i + 1))
      if [ "$_i" -ge "${#_argv[@]}" ]; then
        echo "record-review.sh: --recorded-head needs a value (the 40-hex head the record was minted at) — usage: record-review.sh --check-carry <pr> [owner/repo] [--recorded-diff <64hex> [--recorded-head <40hex>]]" >&2
        exit 2
      fi
      RECORDED_HEAD="${_argv[$_i]}"
      if ! [[ "$RECORDED_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
        echo "record-review.sh: --recorded-head expects a full 40-hex sha (got '$RECORDED_HEAD') — a short sha cannot be compared for equality, and accepting one would silently weaken the pin to a prefix match." >&2
        exit 2
      fi ;;
    --flush-pending) FLUSH_PENDING=1 ;;
    --print-tier) PRINT_TIER=1 ;;
    --delta) DELTA=1 ;;
    --recover-body) RECOVER_BODY=1 ;;
    --force-stale) FORCE_STALE=1 ;;
    --expect-head)
      _i=$((_i + 1))
      if [ "$_i" -ge "${#_argv[@]}" ]; then
        echo "record-review.sh: --expect-head needs a value — usage: record-review.sh <pr> <head_sha> [verdict] [repo] [--evidence <review-artifact>] [--force-stale] [--expect-head <40-hex>]" >&2
        exit 2
      fi
      EXPECT_HEAD="${_argv[$_i]}"
      if ! [[ "$EXPECT_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
        echo "record-review.sh: --expect-head expects a full 40-hex sha (got '$EXPECT_HEAD') — a short sha cannot be compared for equality, and accepting one would silently weaken the pin to a prefix match." >&2
        exit 2
      fi ;;
    --evidence)
      # tortoise#7391: consumes the NEXT argument (the review-artifact reference).
      _i=$((_i + 1))
      if [ "$_i" -ge "${#_argv[@]}" ]; then
        echo "record-review.sh: --evidence needs a value — usage: record-review.sh <pr> <head_sha> [verdict] [repo] [--evidence <review-artifact>] [--force-stale]" >&2
        exit 2
      fi
      EVIDENCE="${_argv[$_i]}" ;;
    --findings)
      # #3400: the open-finding count a `not-clean` record must carry.
      _i=$((_i + 1))
      if [ "$_i" -ge "${#_argv[@]}" ]; then
        echo "record-review.sh: --findings needs a value (the number of OPEN findings the review left) — usage: record-review.sh <pr> <head_sha> not-clean <owner/repo> --findings <n> --evidence <review-artifact>" >&2
        exit 2
      fi
      FINDINGS="${_argv[$_i]}" ;;
    --findings-note)
      # #3400: free-form severity detail (e.g. "1 open P2"), quoted into the
      # gate's message. Never parsed, so it cannot become a second grammar.
      _i=$((_i + 1))
      if [ "$_i" -ge "${#_argv[@]}" ]; then
        echo "record-review.sh: --findings-note needs a value (free-form severity detail, e.g. '1 open P2')" >&2
        exit 2
      fi
      FINDINGS_NOTE="${_argv[$_i]}" ;;
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
# ⛔ THE ONE-VERB RULE COVERS POSITIONALS TOO (round 2, P2). `--recover-body 42 o/r
# clean-low <sha>` passed the bound above, took REPO from $2, and silently DROPPED
# the requested verdict and head — minting the MARKER's verdict with exit 0. The
# read-only modes can ignore extra positionals harmlessly (they mint nothing); a
# MINTING mode must not.
if [ "$DELTA" -eq 1 ] && [ "${#POSITIONAL[@]}" -gt 2 ]; then
  echo "record-review.sh: --delta takes <pr> [owner/repo] and nothing else (got ${#POSITIONAL[@]} positional arguments) — a head/verdict here would be silently IGNORED, and this verb deliberately reads BOTH from the record: the reviewed head is what the delta is measured from, so a caller-supplied one could attest a delta nobody reviewed." >&2
  exit 2
fi
if [ "$RECOVER_BODY" -eq 1 ] && [ "${#POSITIONAL[@]}" -gt 2 ]; then
  echo "record-review.sh: --recover-body takes <pr> [owner/repo] and nothing else (got ${#POSITIONAL[@]} positional arguments) — a head/verdict here would be silently IGNORED, and this verb would mint the marker's verdict while you believed you had chosen one. Recover, then record a fresh verdict as a separate command if one is owed." >&2
  exit 2
fi
if [ "${#POSITIONAL[@]}" -gt 0 ]; then
  set -- "${POSITIONAL[@]}"
else
  set --
fi
PR="${1:?usage: record-review.sh <pr> <head_sha> [verdict] [repo] [--force-stale] [--evidence <artifact>]}"
# ⛔ ONE VERB PER INVOCATION (review, #2872 P2). The modes are mutually exclusive
# answers, and the SILENT failure is the dangerous shape: with
# `--recover-body --check-carry` the check-carry block exits first, so the caller
# gets `head`/`carry` and a ZERO exit while NOTHING was written — the mirror image
# of accepting a minting flag. It is refused HERE, above the mode dispatch, because
# `--print-diff-hash` takes the FIRST branch and would otherwise never see it.
# ⛔ --delta IS A MINTING VERB TOO, and it was left OUT of this guard in the first cut — MEASURED
# by a reviewer against a real fixture: `--delta --print-diff-hash <pr> <repo>` exited 0 with the
# record UNTOUCHED (the read-only verb answered and exited first), so the lane saw success and no
# re-attestation happened; `--delta --check-carry` was worse — it answered `fresh … run the
# code-review skill`, i.e. exactly the paid re-review this verb exists to remove. One verb per line.
# ⛔ THREE VERBS, ONE GUARD (rebase resolution of #10522 x #10583). `--flush-pending` (#10522) and
# `--delta` (#10583) landed from opposite sides of the same day, and their flags interlock exactly
# like the pairs above: `--flush-pending --delta` would deliver the pending marker, exit 0 at the
# FLUSH block above, and never measure a delta — a successful exit that re-attested nothing, which
# is the shape this guard exists to refuse. So every minting/read-only pair is refused in ONE place,
# and the mixed mint pair (`--recover-body --delta`) is refused explicitly: both write a record, and
# whichever ran second would silently discard the first one's provenance.
if [ "$FLUSH_PENDING" -eq 1 ] && { [ "$CHECK_CARRY" -eq 1 ] || [ "$PRINT_DIFF_HASH" -eq 1 ] || [ "$PRINT_TIER" -eq 1 ] || [ "$RECOVER_BODY" -eq 1 ] || [ "$DELTA" -eq 1 ]; }; then
  echo "record-review.sh: --flush-pending is its own verb and cannot be combined with --check-carry/--recover-body/--delta/--print-diff-hash/--print-tier — run one verb at a time." >&2
  exit 2
fi
if [ "$RECOVER_BODY" -eq 1 ] && [ "$DELTA" -eq 1 ]; then
  echo "record-review.sh: --recover-body and --delta both MINT a record, so one would silently overwrite the other's provenance — run one verb at a time: recover (or delta), then record a fresh verdict separately if one is owed." >&2
  exit 2
fi
if { [ "$RECOVER_BODY" -eq 1 ] || [ "$DELTA" -eq 1 ]; } && { [ "$CHECK_CARRY" -eq 1 ] || [ "$PRINT_DIFF_HASH" -eq 1 ] || [ "$PRINT_TIER" -eq 1 ]; }; then
  if [ "$DELTA" -eq 1 ]; then
    echo "record-review.sh: --delta MINTS a record and cannot be combined with --check-carry/--print-diff-hash/--print-tier on one command line — the read-only verb answers and exits first, so a successful-looking exit would have written nothing (measured: exit 0 with the record untouched). Run one verb at a time: ask, then delta." >&2
  else
    echo "record-review.sh: --recover-body is a MINTING verb and cannot be combined with --check-carry/--print-diff-hash/--print-tier on one command line — the read-only mode answers and exits first, so a successful-looking exit would have written nothing. Run one verb at a time: recover, then ask." >&2
  fi
  exit 2
fi
if [ "$PRINT_DIFF_HASH" -eq 1 ] || [ "$PRINT_TIER" -eq 1 ]; then
  # Read-only positional shape: <pr> [owner/repo]. There is NO head_sha and NO
  # verdict here — a selector that answers about the PR's current head must not
  # also be handed the thing it is asked to choose.
  SHA=""
  VERDICT=""
  REPO="${2:-}"
elif [ "$CHECK_CARRY" -eq 1 ] || [ "$RECOVER_BODY" -eq 1 ] || [ "$FLUSH_PENDING" -eq 1 ] || [ "$DELTA" -eq 1 ]; then
  # Same shape, same reason. --check-carry answers the lane's question with the
  # merge gate's own predicate instead of leaving it to inference; --recover-body
  # takes <pr> [owner/repo] because a record is identified by BOTH.
  SHA=""
  VERDICT=""
  REPO="${2:-}"
  # ⛔ A FLAG THAT CANNOT AFFECT A READ-ONLY ANSWER IS REFUSED, NOT IGNORED.
  # `--evidence`/`--force-stale`/`--expect-head` are RECORD-MINTING inputs; this
  # mode writes nothing, so accepting them would make the caller believe it had
  # recorded (or pinned) something it did not. Same posture as the removed
  # --second-model flag above.
  if [ -n "$EVIDENCE" ] || [ "$FORCE_STALE" -eq 1 ] || [ -n "$EXPECT_HEAD" ]; then
    if [ "$RECOVER_BODY" -eq 1 ]; then
      echo "record-review.sh: --recover-body restores a verdict that was ALREADY recorded, so it takes no --evidence/--force-stale/--expect-head — those describe a review to mint, and accepting them here would let a recovered record claim evidence no reviewer produced. Recover first, then record a fresh verdict separately if one is owed." >&2
    elif [ "$FLUSH_PENDING" -eq 1 ]; then
      echo "record-review.sh: --flush-pending only DELIVERS a marker a previous run already minted — it takes no --evidence/--force-stale/--expect-head, which describe a record to mint. Flush first, then record separately if a verdict is owed." >&2
    elif [ "$DELTA" -eq 1 ]; then
      echo "record-review.sh: --delta re-binds the record's OWN verdict onto the live head, so it takes no --evidence/--force-stale/--expect-head — those describe a review to mint, and a delta is precisely the case where NO reviewer ran. If a new review did run, record it normally instead." >&2
    else
      echo "record-review.sh: --check-carry is READ-ONLY (it answers 'would this record carry?' and writes nothing), so it takes no --evidence/--force-stale/--expect-head — those describe a record to mint. Run the mode without them, then record separately if the answer is 'fresh'." >&2
    fi
    exit 2
  fi
else
  SHA="${2:?missing head_sha}"
  VERDICT="${3:-clean}"
  REPO="${4:-}"
fi
case "$VERDICT" in
  clean|clean-micro|clean-low|not-clean) ;;
  *)
    # --print-diff-hash carries NO verdict (it writes nothing), so only the
    # record path is refused here. The arm is expressed this way — rather than
    # folding the case into the else above — so the mutation harness's
    # `sed 's#^  clean|clean-micro|clean-low) ;;#…#'` anchor keeps matching.
    # --recover-body is here for the same reason (#2872): it takes its verdict
    # from the SIGNED marker it verifies, never from the command line.
    if [ "$PRINT_DIFF_HASH" -ne 1 ] && [ "$CHECK_CARRY" -ne 1 ] && [ "$PRINT_TIER" -ne 1 ] && [ "$RECOVER_BODY" -ne 1 ] && [ "$FLUSH_PENDING" -ne 1 ] && [ "$DELTA" -ne 1 ]; then
      echo "verdict must be 'clean', 'clean-micro', 'clean-low' or 'not-clean'; refusing to record '$VERDICT'" >&2; exit 2
    fi ;;
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
# ── #3400: `--findings` binds to `not-clean` and to nothing else ───────────
# Both directions are refusals, because both are silent otherwise: a clean
# record that quietly swallowed `--findings 3` would look like it had recorded
# the findings, and a `not-clean` record with no count leaves the gate able to
# say only "something was wrong", which is barely better than "no record".
if [ "$VERDICT" = "not-clean" ]; then
  if [ -z "$FINDINGS" ]; then
    echo "record-review.sh: the 'not-clean' verdict requires --findings <n> — a negative verdict asserts that a review found something OPEN, and a count is the minimum that makes that assertable to the gate (which otherwise can only report 'a record exists whose verdict is not clean'). Nothing was recorded." >&2
    exit 2
  fi
  # ⛔ CANONICALISE THE COUNT — DO NOT MERELY ACCEPT IT (review, P2-1). The count
  # is written UNQUOTED (`"findings":$FINDINGS`) because every reader binds a JSON
  # NUMBER (review-enforcer: `typeof record.findings === "number"`), so the
  # spelling of the value IS the record's validity, not a formatting nicety.
  #
  # Measured against the previous arms: `^[0-9]+$` accepts `007`, and
  # `[ 007 -lt 1 ]` is FALSE (bash reads a leading zero as OCTAL), so `--findings 007`
  # was accepted and wrote `"findings":007` — invalid JSON, therefore an
  # UNREADABLE record, therefore a gate that reports "No review record found" over
  # a review that DID happen and WAS correct. `08` was worse still: `-lt` aborts the
  # test with "value too great for base", and stderr noise does not make the record
  # any more parseable. Fail-closed both times (a broken record cannot license a
  # merge), but the arm silently destroyed a CORRECT negative record, so it did not
  # hold its own contract.
  #
  # Why COERCE rather than refuse: `007` is a caller TYPO, not a lie about the
  # review, and the count it denotes is unambiguous — seven. The strip below is
  # pure STRING manipulation (no `10#` arithmetic), so a pathologically long value
  # cannot wrap or overflow into a different number than the caller wrote.
  if ! [[ "$FINDINGS" =~ ^[0-9]+$ ]]; then
    echo "record-review.sh: --findings expects a POSITIVE integer (got '$FINDINGS') — 'not-clean' with zero findings is a contradiction: that is what 'clean' means. Nothing was recorded." >&2
    exit 2
  fi
  # `${FINDINGS%%[!0]*}` is the leading-ZERO RUN (empty when it does not start with
  # 0); removing it from the front yields the canonical decimal (`007` → `7`,
  # `08` → `8`, `12` → `12`).
  FINDINGS_ZEROS="${FINDINGS%%[!0]*}"
  FINDINGS="${FINDINGS#"$FINDINGS_ZEROS"}"
  if [ -z "$FINDINGS" ]; then
    echo "record-review.sh: --findings expects a POSITIVE integer, and the value given ('${FINDINGS_ZEROS}') is zero — 'not-clean' with zero findings is a contradiction: that is what 'clean' means. Nothing was recorded." >&2
    exit 2
  fi
  if [[ "$FINDINGS_NOTE" == *'"'* || "$FINDINGS_NOTE" == *'\\'* || "$FINDINGS_NOTE" =~ [[:cntrl:]] ]]; then
    echo "record-review.sh: --findings-note must be a single-line plain string (no quotes, backslashes or control characters) — it is embedded in the record's JSON, and an unescaped character would make the record unreadable (which the merge gate treats as NO record)." >&2
    exit 2
  fi
elif [ -n "$FINDINGS" ] || [ -n "$FINDINGS_NOTE" ]; then
  echo "record-review.sh: --findings/--findings-note describe a NEGATIVE verdict and are only meaningful with 'not-clean' (got verdict '$VERDICT'). Accepting them here would let the caller believe findings were recorded when the record cannot carry them." >&2
  exit 2
fi
# ── #3315: the caller-supplied pair is a --check-carry INPUT, nothing else ──
# Refusing it on the minting/selector modes is the same posture as --evidence:
# a flag that cannot affect what this invocation does must not be accepted, or
# the caller believes it pinned something it did not. `--recorded-head` alone is
# refused too: a head answers no question about CONTENT identity, which is the
# only question a carry asks.
if [ -n "$RECORDED_DIFF" ] || [ -n "$RECORDED_HEAD" ]; then
  if [ "$CHECK_CARRY" -ne 1 ]; then
    echo "record-review.sh: --recorded-diff/--recorded-head describe the RECORD a carry question is about, so they are only meaningful with --check-carry (which writes nothing). This invocation is a different verb, where they would be IGNORED." >&2
    exit 2
  fi
  if [ -z "$RECORDED_DIFF" ]; then
    echo "record-review.sh: --recorded-head needs --recorded-diff — a head alone answers no question about content identity, and accepting it would let it look as though a carry had been checked." >&2
    exit 2
  fi
fi
# Input validation (#2055): the ai-review-gate binds the FULL 40-char sha and
# a numeric PR — reject bad inputs up front rather than posting evidence that
# can never verify.
if ! [[ "$PR" =~ ^[0-9]+$ ]]; then
  echo "PR number must be numeric; refusing to record '$PR'" >&2; exit 2
fi
if [ "$PRINT_DIFF_HASH" -eq 0 ] && [ "$CHECK_CARRY" -eq 0 ] && [ "$PRINT_TIER" -eq 0 ] && [ "$RECOVER_BODY" -eq 0 ] && [ "$FLUSH_PENDING" -eq 0 ] && [ "$DELTA" -eq 0 ] && ! [[ "$SHA" =~ ^[0-9a-f]{40}$ ]]; then
  echo "head_sha must be a full 40-char hex sha (got '${SHA:0:12}…'); refusing to record" >&2; exit 2
fi
# tortoise#7391: the sha the CALLER named, kept before any carry re-binds $SHA to the
# current head. A carried record's `carried_from` (and the head the recovered
# mint time belongs to) is this one, not the head it is carried onto.
ORIG_SHA="$SHA"
# Set by the carry arms below; initialised here so the tortoise#7391 evidence gate can
# read it unconditionally under `set -u`.
CARRY_ARM=""
# ── CARRY PROVENANCE (#10177, defect B) ───────────────────────────────────
# A carried record used to keep NOTHING about what it carried: `diff_sha256` is
# re-derived from the LIVE head (so it always equals what would merge — it can
# never show that the reviewer saw something else), `evidence` was omitted
# entirely, and the arm that justified the carry left no trace. So a carry was
# indistinguishable, after the fact, from a stale re-record — and the measured
# instance had exactly that shape. These three fields are the proof, written
# into the record: WHICH arm proved the artifact unchanged, the digest of the
# artifact as REVIEWED (not as it will merge), and the digest of the delta the
# head added beyond the reviewed one.
CARRY_REVIEWED_DIFF=""
CARRY_REVIEWED_SOURCE=""
CARRY_DELTA_DIFF=""
CARRY_EVIDENCE=""
# Per-ARM marker provenance: each carry arm records the marker IT verified, and
# the evidence fallback reads the pair belonging to the arm that actually fired
# (fresh-review cycle 3 — a shared pair let one arm report another's signature).
DIFF_ARM_SIG=""
DIFF_ARM_SHA=""
PATCH_ARM_SIG=""
PATCH_ARM_SHA=""
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
# ── --flush-pending: DELIVER a marker a previous run minted but could not post ──
# The mirror image of defect A's exit 0: the marker bytes survived in the pending
# file, so the evidence can be made visible WITHOUT paying for a second review and
# WITHOUT diluting the evidence (a re-record would do both).
if [ "$FLUSH_PENDING" -eq 1 ]; then
  # A PENDING MARKER IS FILED UNDER ITS REPO, so without one the lookup below would
  # test the LEGACY filename and answer "nothing pending" (exit 0) over a stranded
  # repo-qualified marker — a false success in exactly the throttled window that
  # strands markers (fresh-review cycle 2, P1). Refuse to answer instead.
  if [ -z "$REPO" ]; then
    echo "record-review.sh --flush-pending: no owner/repo resolved, and a pending marker is filed per repo — pass it explicitly: record-review.sh --flush-pending $PR owner/repo. Nothing was read and nothing was written." >&2
    exit 2
  fi
  FP_FILE="$(marker_pending_file "$REPO" "$PR")"
  if [ ! -f "$FP_FILE" ]; then
    echo "record-review.sh --flush-pending: nothing pending for ${REPO:-<no repo>}#$PR — a marker minted by a previous run either reached the body, or none was stranded. Nothing was written." >&2
    exit 0
  fi
  if flush_pending_markers "$REPO" "$PR"; then
    # ⛔ NO SIGNEDNESS CLAIM (#3168 re-review P3): this arm is reached with MARKER_SIGNED=0
    # too — and so is every site that writes a pending file (:4845, :4887, :4910). The
    # signing block sits ABOVE the persistence (:4822-4834), so the ORDER is not the
    # reason: both branches of that block CONTINUE on failure — no gate key (:4831-4833),
    # or a keyed run whose openssl produced nothing (:4827-4829) — each setting
    # MARKER_SIGNED=0 and falling through to the body read. The bytes a flush holds need
    # not carry a `sig=` at all, and `--flush-pending` cannot know which case it is: it
    # delivers whatever the pending file holds. This line used to call them "the pending
    # signed marker"; the noun now claims only what is observed.
    echo "record-review.sh --flush-pending: delivered the pending marker for ${REPO}#$PR to the PR body — no new review was owed and none was recorded"
    exit 0
  fi
  echo "⛔ body-marker-unposted: the pending marker for ${REPO}#$PR is STILL not in the body (gh refused, the API is throttled, the body could not be read, or the pending file is EMPTY — see the reason above). It is KEPT at ${FP_FILE/#$HOME/~} for a later --flush-pending; this is not a re-review and not a new record. If the file is empty, re-run the recorder at the same head with gh available so the marker is rebuilt from the record." >&2
  exit 5
fi
# A pending marker left by an EARLIER run of this PR is delivered by any later
# minting run — that is what makes the documented remedy ("re-run to retry the
# post") actually work. Best-effort here: this run's own post, and its own
# `body-marker-unposted` exit, still govern below.
if [ -n "$REPO" ] && [ -f "$(marker_pending_file "$REPO" "$PR")" ] && command -v gh >/dev/null 2>&1; then
  flush_pending_markers "$REPO" "$PR" >/dev/null 2>&1 || true
fi

# ── --delta (#10583): RESOLVE THE DELTA BEFORE ANY SHA/VERDICT VALIDATION ─────
# THE GAP THIS CLOSES, MEASURED. The predicate for "the head moved, the authored
# change did not" already exists (`lane_dimension_carry`, clauses A-D). But it is
# only reachable from the STALE-SHA GUARD, which fires on `$SHA != $CURRENT_HEAD`.
# A lane that records at the LIVE head — the correct-looking command, and the one
# the gate's own brief teaches — never enters that branch, so `CARRY_ARM` stays
# empty, the fresh-clean rule then demands `--evidence`, and the lane concludes
# "needs review". That is how a conflict-free forward-merge of `main` into 8
# branches became 8 full re-reviews of code nobody touched (#10583).
# So this verb supplies the ONE input the caller should not have to remember — the
# REVIEWED head, read from the record — and then hands the decision to the SAME
# arms. It adds no predicate: the verdict re-bound is the record's own, the head it
# is measured FROM is the record's own, and the refusal path is unchanged.
# ⛔ It is STRICTER than the paths it replaces, never a bypass:
#   · the previous verdict must be clean-family (a delta re-binds an APPROVAL);
#   · a previous CARRY that records no PROOF is refused, exactly as `--check-carry` refuses it
#     (see the `carried|delta` block below — the measured shape is `--delta` saying "Land it"
#     exit 0 over a record the merge gate answers as `norecord`);
#   · --evidence/--force-stale/--expect-head are REFUSED (no reviewer ran);
#   · clauses (A)-(D) and clause (E) all still run, so a measurably red target still refuses, and
#     so do the lane arm's own requirements (a forward move with no intervening authored non-merge
#     commit and a clean re-merge of the head). The ARM boundary matters and is stated precisely
#     rather than claimed wholesale: a rewritten (rebased) head is refused by the LANE arm
#     (clause B is an ancestry test), while the `diff`/`patch` arms legitimately re-bind when the
#     ARTIFACT ITSELF is byte-identical across the rewrite — that is exactly the #2982/#1377 class
#     those two arms exist for, so no ancestry requirement is added to them here.
if [ "$DELTA" -eq 1 ]; then
  if [ -z "$REPO" ]; then
    echo "record-review.sh --delta: no repo resolved — a delta is measured in GIT against the PR's authoritative base, so it needs owner/repo explicitly: record-review.sh --delta $PR owner/repo" >&2
    exit 2
  fi
  D_DIR="$HOME/.pi/agent/reviews"
  D_FILE="$D_DIR/${REPO%/*}-${REPO#*/}-$PR.json"
  D_LEGACY="$D_DIR/$PR.json"
  # Same field reader, same collision rule (an embedded repo that differs is a
  # DIFFERENT record) and same legacy rule as --check-carry above. It is a COPY, not a shared
  # definition: `cc_field`/`cc_names_this_repo` are defined further down, inside the
  # `--check-carry` block, and are not in scope here. Kept in step BY HAND — so a future change to
  # the gate-mirroring lookup must be made in BOTH places (or this block must be hoisted above the
  # two verbs); the comment used to claim the lookup was "shared", which it never was.
  d_field() { command sed -n "s/.*\"$2\":\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | command head -1 || true; }
  D_REC=""
  if [ -f "$D_FILE" ]; then
    D_R="$(d_field "$D_FILE" repo)"
    if [ -z "$D_R" ] || [ "$D_R" = "$REPO" ]; then D_REC="$D_FILE"; fi
  elif [ -f "$D_LEGACY" ]; then
    D_R="$(d_field "$D_LEGACY" repo)"
    if [ -z "$D_R" ] || [ "$D_R" = "$REPO" ]; then D_REC="$D_LEGACY"; fi
  fi
  if [ -z "$D_REC" ]; then
    echo "record-review.sh --delta: no review record for $REPO#$PR — a delta RE-BINDS a verdict that exists; with none there is nothing to re-bind. Run the review, post its verdict, and record it with --evidence comment:<id>." >&2
    exit 4
  fi
  D_HEAD="$(d_field "$D_REC" head_sha)"
  D_VERDICT="$(d_field "$D_REC" verdict)"
  D_MINT="$(d_field "$D_REC" mint)"
  # ⛔ THE GATE'S OWN PROVENANCE PREDICATE, APPLIED HERE TOO (#10177 × #10583). `--check-carry`
  # treats a `carried`/`delta` record that records NO PROOF as NO RECORD (exit 4). Without this,
  # `--delta` answered "ALREADY bound … Land it" (exit 0) over exactly that record — MEASURED on a
  # record at the live head with `mint:"delta"` and neither `carry_arm` nor `evidence`: `--delta`
  # → rc 0 "Land it", `--check-carry` → `norecord`, rc 4. A successful exit over an artifact the
  # merge gate rejects is the false PASS this whole file refuses, so the rule is applied BEFORE
  # the already-bound short circuit and before any git work — the same order `--check-carry` uses,
  # and the same exit status (4, `norecord`) so the two verbs cannot disagree about one record.
  case "$D_MINT" in
    carried|delta)
      D_ARM_F="$(d_field "$D_REC" carry_arm)"
      D_EV_F="$(d_field "$D_REC" evidence)"
      if [ -z "$D_ARM_F" ] || [ -z "$D_EV_F" ]; then
        echo "⛔ --delta REFUSED for $REPO#$PR: the record is a CARRY (mint='$D_MINT') with NO recorded proof (carry_arm='${D_ARM_F:-}', evidence='${D_EV_F:-}'), so it is NOT a record the merge gate accepts — the READ-ONLY verb --check-carry answers norecord for it, and a delta over it would re-bind a verdict with nothing in the record a reader could check (the tortoise#10677 shape). Nothing was written. Re-record at the current head WITH the review's evidence (--evidence comment:<id>), which mints a record that names what it carried." >&2
        exit 4
      fi ;;
  esac
  case "$D_HEAD" in *[!0-9a-f]* | "") D_HEAD="" ;; esac
  if [ "${#D_HEAD}" -ne 40 ]; then
    echo "record-review.sh --delta: the record for $REPO#$PR names no full 40-hex head_sha, so the head the review happened at is unknown and no delta can be measured from it. Re-record normally." >&2
    exit 3
  fi
  # ⛔ NEVER CLAIM `clean` WHEN THE PREVIOUS VERDICT WAS NOT CLEAN — a delta
  # re-binds an APPROVAL, and relabelling a non-approval as one is the bypass this
  # whole mode must never become.
  case "$D_VERDICT" in
    clean | clean-micro | clean-low) ;;
    *)
      echo "⛔ --delta REFUSED for $REPO#$PR: the record carries verdict '$D_VERDICT', which is not a clean-family verdict. A delta re-binds an APPROVAL onto a new head; it cannot manufacture one. Nothing was written — a full review is owed." >&2
      exit 3 ;;
  esac
  D_LIVE="$(command gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null || true)"
  case "$D_LIVE" in *[!0-9a-f]*) D_LIVE="" ;; esac
  if [ "${#D_LIVE}" -ne 40 ]; then
    echo "record-review.sh --delta: the PR head could not be READ — this is NOT a changed diff and NOT a refusal. RETRY (a contended gh gate or a rate-limit window is far cheaper than a re-review)." >&2
    exit 3
  fi
  if [ "$D_HEAD" = "$D_LIVE" ]; then
    echo "record-review.sh --delta: the record for $REPO#$PR is ALREADY bound to the live head (${D_HEAD:0:12}…) — nothing is stale and nothing needs re-attestation. Land it." >&2
    exit 0
  fi
  echo "DELTA-PAIR($REPO#$PR) from=${D_HEAD:0:12}… to=${D_LIVE:0:12}… verdict=$D_VERDICT prior-mint=${D_MINT:-none}" >&2
  DELTA_FROM="$D_HEAD"
  # The reviewed head and its verdict are now THIS invocation's inputs, so the
  # stale-sha guard, the arms, clause (E) and the evidence rule all behave exactly
  # as they do for a hand-passed stale sha — no second code path decides.
  SHA="$D_HEAD"
  ORIG_SHA="$D_HEAD"
  VERDICT="$D_VERDICT"
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
# The bytes come from the GitHub REST API, exactly as the workflow does. Fall
# back to a LOCAL `git diff` ONLY when the API REFUSES the diff (#1398).
# The API's `.diff` media type is capped at 300 files: a larger PR answers HTTP
# 406 with a `too_large` error body (measured on tortoise#7653, 2,265 files:
# 337 bytes of JSON on stdout, exit 1), so no digest — and therefore no `diff=`
# identity — could be minted for it. That made such a PR structurally
# unlandable once `main` drifted: a base-refresh moves the head, and there is
# no content identity for the carry to match. The fallback computes
# `git diff <base>...<head>` in a local checkout and pushes it through the SAME
# `diff-normalize.py`, so the local and API renderings stay comparable.
#
# WHAT THE FALLBACK DOES AND DOES NOT GUARANTEE. The normalizer erases the
# fields that legitimately move between renderings it was designed for — the
# `index` abbreviation line and the hunk-header START line — so an under-cap API
# rendering and the local `git diff` of the SAME content normalize to the SAME
# digest (MEASURED: agent-infra PRs #1626/#1620/#1619/#1615/#1612/#1609/#1606/
# #1600/#1599/#1598/#1596/#1595/#1594/#1590/#1583/#1579/#1576/#1568/#1566/#1561/
# #1555/#1554 all agree byte-for-byte after normalization while their RAW
# digests differ). It does NOT erase the hunk SECTION HEADING, and GitHub's
# heading heuristic is not always git's: even `gh:python` renders
# `@@ … @@ def _signature_from(…)` where a default local `git diff` renders
# `@@ … @@ _GUARD_KEY_RE = re.compile(…)` (MEASURED on PR #1582/#1570/#1548).
# That divergence is FAIL-CLOSED: it can only refuse a carry (a fresh review
# is demanded), never accept one — the two renderings never collide onto one
# digest for DIFFERENT content. Within one path the digest is deterministic, so
# an over-cap PR re-recorded after a base refresh at the same head still
# carries. Binary entries are the same shape of residual: their `index` line is
# kept verbatim (the 2026-09-23 amendment), so a different abbreviation width
# diverges there too — again fail-closed.
#
# Hash the FILE, not a command substitution: `x="$(cmd)"` strips trailing
# newlines and would change the digest.
#
# Empty when gh/API/openssl is unavailable AND no local checkout can mint a
# digest → the marker falls back to the legacy sha-only shape, and the gate's
# sha-match path still governs.
DIFF_NORMALIZER="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/lib/diff-normalize.py"
DIFF_HASH=""
# #1362 D1 — the sha256 over the RAW diff (the pre-normalization binding). Kept
# ONLY so the carry-forward arm can accept a marker minted before this change;
# nothing else reads it. Both hashes come from ONE diff fetch.
LEGACY_DIFF_HASH=""
# #1577/#1398 — how the diff read ENDED, so the warning can name the condition
# instead of implying a content change:
#   "ok"          the body was read (API, or the local #1398 fallback)
#   "empty"       a 2xx whose body was 0 bytes    (a property of the DIFF)
#   "too_large"   the API refused the diff at its 300-file cap (#1398)
#                 (a property of the PR's SIZE — STRUCTURAL, not retryable)
#   "nondiff"     a 2xx whose body carried no `diff --git` entry boundary
#                 (an error body, or any 2xx that is not a diff — NEVER hashed;
#                 #1398. NOTE the residual the measured mode does NOT exercise: a
#                 PARTIAL truncation that still carries one entry boundary is not
#                 detectable this way. #1398 measured the cap as HTTP 406 with no
#                 entry boundary at all, so this is not currently reachable; if it
#                 ever appears, the `changed_files` count comparison the issue
#                 names is the remedy — see the `diff_fetch_once` doc below.)
#   "unavailable" a failed read, or no read at all (a property of the NETWORK)
# Only "empty" can mean "a fresh review is owed"; "unavailable" means "retry".
# "too_large" is structural: retrying answers the same 406, so it is not retried
# and its warning must not send an operator hunting a gh/auth fault.
# The stale-sha guard already states this policy for the HEAD read ("a transient
# gh/API failure must not block a legitimate record", see the block below), but
# the DIFF read is the one that actually refused: an empty DIFF_HASH leaves the
# carry nothing to compare, and the refusal it produced -- "the reviewed diff
# CHANGED" -- demands the MOST expensive remedy in the system.
DIFF_FETCH="unavailable"
DIFF_FETCH_TRIES=0
# #1398 — set when the digest was minted from a LOCAL checkout instead of the
# API (only reachable through the size-cap arm). LOCAL_DIFF_ROOT names the
# checkout so the provenance is visible in the warning rather than implied.
LOCAL_DIFF=""
LOCAL_DIFF_ROOT=""
# The checkout the #1398 fallback resolves from. Defaults to the invoking
# session's cwd (the session is normally working IN the PR's repo). Overridable
# so a caller — or the suite — can point at a specific clone. A wrong or absent
# checkout fails CLOSED (legacy marker), never a wrong digest.
LOCAL_DIFF_REPO="${RECORD_REVIEW_LOCAL_REPO:-.}"
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
# #1398 — CLASSIFY BY CONTENT, NEVER BY EMPTINESS OR EXIT CODE ALONE.
# The size-cap arm is the trap this guard exists for, and it is NOT hypothetical:
# GitHub's 406 body is NON-EMPTY (337 bytes, measured on tortoise#7653). The only
# thing that stopped a `[ -s "$f" ]` from accepting it was the `&&` short-circuit
# on the non-zero exit — so any "fix" that relaxes the short-circuit (e.g. `|| true`
# so a retry arm can inspect the result) would make `[ -s ]` PASS on 337 bytes of
# ERROR MESSAGE and hash it as the reviewed diff. Every >300-file PR would then
# share ONE constant digest: the collision ⇒ false-accept direction #1398 exists
# to prevent. So the body is classified by what it IS.
#
# A body is an ERROR OBJECT when it carries no entry boundary AND is (however
# WRAPPED) a JSON object declaring an HTTP status or the `too_large` code. The
# entry-boundary exclusion runs FIRST and alone holds the invariant that a real
# diff is never demoted: a diff always carries `diff --git`, so the exclusion
# fires before any JSON test, and its content lines are prefixed (`+`, `-`, ` `)
# so no diff line can even begin with `{`. Once a body is known NOT to be a diff,
# the only remaining question is WHICH non-diff it is — so the JSON test is
# deliberately insensitive to how the envelope is formatted.
#
# That insensitivity is the point. An earlier revision additionally required the
# body to be a SINGLE LINE (`grep -c ''` ≤ 1), which classified today's real GitHub
# 406 only because GitHub emits it on one line. A PRETTY-PRINTED or re-wrapped 406
# then fell through the size-cap arm and the local fallback was SKIPPED —
# returning the oversized PR to the very unlandability #1398 exists to remove —
# and the operator was misdiagnosed. The MEASURED 406 exits NON-ZERO with the
# envelope on stdout, so it fell to the retryable `unavailable` arm and the
# warning blamed gh/auth/network (and retried a STRUCTURAL refusal); a 2xx
# non-diff fell to `nondiff` and blamed a missing entry boundary. Either way the
# issue's misdiagnosis half re-entered through a different door. (The finding's
# short form said "falls to `nondiff`": true for the exit-0 shape, while the
# exit-1 shape is the measured one — 11.11n–p cover both.) The line count was
# never what protected a real diff — the boundary exclusion precedes it — it only
# made the classifier formatting-dependent.
# --- #1398 body classification -------------------------------------------------
# The text predicates below take the SAME flattened string, so a `"status"` /
# `"code"` VALUE sitting on its own line classifies identically to one on the same
# line. Sharing the flatten is the fix: `diff_body_is_size_cap` used to re-grep the
# ORIGINAL, line-oriented body, where `[[:space:]]*` cannot cross a newline, so an
# envelope re-wrapped between a key's colon and its value slipped out of the
# size-cap arm even though the error-object classifier had already recognised it.
# A HERE-STRING, not a pipe: `tr … | grep -q` under this script's `set -o pipefail`
# can report a FALSE NEGATIVE when grep matches early and tr takes SIGPIPE (#841).
flat_body_is_error_object() { # <flat> -> 0 when the flat text is a JSON error object
  command grep -qE '^\{.*"status"[[:space:]]*:[[:space:]]*"?[45][0-9]{2}"?.*\}$' <<<"$1" 2>/dev/null && return 0
  command grep -qE '^\{.*"code"[[:space:]]*:[[:space:]]*"too_large".*\}$' <<<"$1" 2>/dev/null && return 0
  return 1
}
# The specific STRUCTURAL failure: GitHub refuses to render a diff above 300
# files. Recognised by `"code":"too_large"` or `"status":"406"` — the two facts
# the production measurement recorded verbatim. It runs on the FLATTENED body, so
# `[[:space:]]*` bridges a line break the source may have carried.
flat_body_is_size_cap() { # <flat> -> 0 when the flat text declares the 300-file cap
  command grep -qE '"status"[[:space:]]*:[[:space:]]*"?406"?' <<<"$1" 2>/dev/null && return 0
  command grep -qE '"code"[[:space:]]*:[[:space:]]*"too_large"' <<<"$1" 2>/dev/null && return 0
  return 1
}
# Flatten a non-diff body into one whitespace-trimmed line so the two predicates
# above classify a one-line and a pretty-printed / re-wrapped object identically.
# Returns 1, printing nothing, for: an EMPTY file; a body carrying a `^diff --git`
# entry boundary (tested FIRST, so a real diff is never demoted, whatever JSON it
# contains); and a body larger than ${RECORD_REVIEW_BODY_MAX_BYTES:-262144}.
# The size bound is deliberate, not an assumption: materialising the body as a
# shell string is O(size) (a 2 MB envelope cost ~2.3 s), so an over-size non-diff
# body is refused here rather than flattened. It then falls to the caller's
# `nondiff`/retryable arms — fail-closed either way, and never hashed.
diff_body_flatten() { # <file> -> flattened body on stdout
  local flat max="${RECORD_REVIEW_BODY_MAX_BYTES:-262144}"
  [ -s "$1" ] || return 1
  command grep -qE '^diff --git ' "$1" 2>/dev/null && return 1
  # Flatten the (non-diff, therefore size-bounded) envelope, then trim the
  # surrounding whitespace so `^\{` / `\}$` are not layout-dependent.
  [ "$(command wc -c < "$1" 2>/dev/null || echo 0)" -le "$max" ] || return 1
  flat="$(command tr -d '\r\n' < "$1" 2>/dev/null || true)"
  flat="${flat#"${flat%%[![:space:]]*}"}"     # trim leading whitespace
  flat="${flat%"${flat##*[![:space:]]}"}"     # trim trailing whitespace
  printf '%s' "$flat"
}
diff_body_is_size_cap() { # <file> -> 0 when the body declares the 300-file cap
  local flat
  flat="$(diff_body_flatten "$1")" || return 1
  flat_body_is_error_object "$flat" || return 1
  flat_body_is_size_cap "$flat"
}
# #1398 — mint a diff identity LOCALLY when the API refuses the diff for an
# oversized PR. Only ever called for the size-cap arm; every other failure keeps
# today's legacy-marker degradation.
#
# The checkout must BE the PR's repo (`origin` normalised against $REPO) and must
# be able to produce both revisions. Missing objects are the COMMON case, not an
# edge: `atomic-land.sh` moves the head with a server-side `gh pr update-branch`,
# so the post-update merge commit exists ONLY on the remote. Without a fetch the
# fallback would fail after the head already moved — converting today's
# PRE-update refusal (over-block) into an accept-and-spend, the exact mode
# atomic-land's own guard exists to prevent. So a BOUNDED, read-only fetch of the
# PR head and base ref is attempted when (and only when) an object is absent;
# the fetched head is then required to be the API's declared `.head.sha`, so a
# concurrent head move degrades rather than binding the wrong content.
# `RECORD_REVIEW_LOCAL_DIFF_NOFETCH=1` disables the fetch (a narrowing knob used
# by the hermetic suite, never a way to mint a digest). Replace refs and the
# grafts FILE are neutralised because either can present a different content graph
# than the one really in the clone. On ANY doubt → non-zero → legacy marker.
#
# `--no-ext-diff`/`--no-textconv` are load-bearing, not tidiness: an external diff
# driver or textconv filter configured in the clone would print arbitrary content
# as the "diff". The prefix/context/algorithm pins neutralise ambient config that
# would otherwise shift the rendering away from the API's.
#
# `--full-index` is a SECURITY pin, not cosmetics (cycle-2 review, #1398): a
# hunk-less (binary) entry has NO hunk, so the normalizer keeps its `index` line
# VERBATIM (the 2026-09-23 amendment), and without this flag the LOCAL
# `core.abbrev` (git's minimum is 4 hex) would decide the binding's collision
# resistance — two different blobs whose 4-hex prefixes collide normalized to one
# digest, a false accept in the carry arm. Full 40-hex blob ids remove that
# widen outright. It cannot reduce API-vs-local agreement for hunk-less entries:
# the API's own index abbreviation is its own width (measured 9 hex here, 13 at
# `microsoft/vscode` scale), so those two renderings may already diverge — a
# fail-closed residual, never a false accept — and `--full-index` merely makes
# the LOCAL side independent of ambient object-store state.
# `diff.suppressBlankEmpty=false` pins the other config that changes the
# normalized bytes (a text-diff rendering knob; false is git's default and
# GitHub's rendering).
local_diff_for_pr() { # <pr> <out> -> 0 when a diff-comparable body was written
  local pr="$1" out="$2" dir="${LOCAL_DIFF_REPO:-.}" root="" url="" norm_url=""
  local meta="" base="" head="" base_ref="" tmp=""
  local -x GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null
  command -v git >/dev/null 2>&1 || return 1
  root="$(command git -C "$dir" rev-parse --show-toplevel 2>/dev/null || true)"
  [ -n "$root" ] || return 1
  url="$(command git -C "$root" config --get remote.origin.url 2>/dev/null || true)"
  norm_url="$(printf '%s' "$url" \
    | sed -e 's#^git@github\.com:##' -e 's#^ssh://git@github\.com/##' \
          -e 's#^https\{0,1\}://github\.com/##' -e 's#\.git$##')"
  [ "$norm_url" = "$REPO" ] || return 1
  # The base/head identity is the API's OWN declaration (same as the diff the API
  # would have rendered) — never a local ref, which a stale origin/… could falsify.
  meta="$(command gh api "repos/$REPO/pulls/$pr" --jq '[.base.sha,.head.sha,.base.ref]|@tsv' 2>/dev/null || true)"
  base="$(printf '%s' "$meta" | cut -f1)"
  head="$(printf '%s' "$meta" | cut -f2)"
  base_ref="$(printf '%s' "$meta" | cut -f3)"
  [ -n "$base" ] && [ -n "$head" ] || return 1
  case "$base$head" in *[!0-9a-f]*) return 1 ;; esac
  if [ "${RECORD_REVIEW_LOCAL_DIFF_NOFETCH:-0}" != "1" ]; then
    # Only fetch what is MISSING, and only the PR's own refs. `refs/pull/<pr>/head`
    # is the canonical remote head, so after `update-branch` it names the merge
    # commit the API reports — the content the record must bind.
    command git -C "$root" cat-file -e "$head^{commit}" 2>/dev/null \
      || command git -C "$root" fetch --quiet --no-tags origin "refs/pull/$pr/head" 2>/dev/null || true
    command git -C "$root" cat-file -e "$base^{commit}" 2>/dev/null \
      || case "$base_ref" in
           ''|*[!A-Za-z0-9._/-]*) : ;;
           *) command git -C "$root" fetch --quiet --no-tags origin "refs/heads/$base_ref" 2>/dev/null || true ;;
         esac
  fi
  command git -C "$root" cat-file -e "$base^{commit}" 2>/dev/null || return 1
  command git -C "$root" cat-file -e "$head^{commit}" 2>/dev/null || return 1
  tmp="$(mktemp 2>/dev/null)" || return 1
  if command git -C "$root" \
       -c diff.noprefix=false -c diff.mnemonicPrefix=false -c diff.relative=false \
       -c diff.suppressBlankEmpty=false \
       diff --no-color --no-ext-diff --no-textconv --full-index \
            --src-prefix=a/ --dst-prefix=b/ --unified=3 --diff-algorithm=myers \
            --find-renames "$base...$head" > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ] \
     && command grep -qE '^diff --git ' "$tmp" 2>/dev/null; then
    command mv "$tmp" "$out"
    LOCAL_DIFF_ROOT="$root"
    return 0
  fi
  rm -f "$tmp"
  return 1
}
# ONE diff read into <out>. The EXIT STATUS carries the reason, which the old
# `cmd && [ -s ]` one-liner threw away:
#   0 = read, 1 = the call FAILED (retryable), 2 = the call SUCCEEDED with a
#   0-byte body (NOT retryable -- an idempotent GET answers the same thing twice),
#   3 = the API refused the diff at its 300-file cap (#1398; STRUCTURAL -- not
#   retryable, and the arm the local fallback exists for),
#   4 = the API answered with a body carrying no `diff --git` entry boundary
#   (#1398; NEVER hashed -- an error body is not a diff). A PARTIAL truncation
#   that retains an entry boundary is NOT caught here: #1398 MEASURED the cap as
#   HTTP 406 with `grep -c '^diff --git'` returning 0, so there is no partial
#   patch to hash and no truncation branch to add.
diff_fetch_once() { # <pr> <out>
  local frc=0
  command gh api -H "Accept: application/vnd.github.v3.diff" \
    "repos/$REPO/pulls/$1" > "$2" 2>/dev/null || frc=$?
  # CONTENT FIRST, before the exit code is even consulted: a 406 body is
  # non-empty, so exit-status-only reasoning has to be paired with a content
  # classification or the body above reaches the hasher.
  if diff_body_is_size_cap "$2"; then return 3; fi
  [ "$frc" -eq 0 ] || return 1
  [ -s "$2" ] || return 2
  command grep -qE '^diff --git ' "$2" 2>/dev/null || return 4
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
    3) DIFF_FETCH="too_large" ;;
    4) DIFF_FETCH="nondiff" ;;
    *) DIFF_FETCH="unavailable" ;;
  esac
  # #1398 — the API REFUSED the diff at its 300-file cap. That is a STRUCTURAL
  # ceiling, not a missing tool, so mint the identity locally instead of
  # degrading: a local `git diff` pushed through the SAME normalizer keeps a
  # >300-file PR landable across a base-refresh. Only the size-cap arm falls
  # back — every other failure keeps today's legacy sha-only marker.
  if [ "$DIFF_FETCH" = "too_large" ] && local_diff_for_pr "$pr" "$tmp"; then
    DIFF_FETCH="ok"
    LOCAL_DIFF="1"
  fi
  if [ "$DIFF_FETCH" = "ok" ] && [ "$LOCAL_DIFF" = "1" ]; then
    echo "ℹ️ #1398: the API cannot render this PR's diff (it exceeds GitHub's documented 300-file cap); the review digest was computed from the LOCAL checkout ${LOCAL_DIFF_ROOT:-<unknown>} through the shared normalizer, so the content identity survives a base-refresh" >&2
  fi
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

# ══════════════════════════════════════════════════════════════════════════
# #1377 — THE PATCH IDENTITY: "did the CHANGE move, or only the RENDERING?"
#
# The evidence binding above answers "is this the same artifact?" and is
# deliberately STRICT: its `diff_sha256` keeps hunk CONTEXT, because #1362 D1
# (owner ruling) refused the whitespace-blind `git patch-id` as a binding. That
# strictness is correct for a binding and it is what makes a changed diff
# impossible to carry — but it also means a REBASE onto a moved base is
# invisible to it: when `main` lands work in the same file, every context line
# around the reviewed change is rewritten, the normalized digest moves, and the
# record goes stale with the REVIEWED LINES UNCHANGED. That is #1377: re-record
# (mechanical), do NOT pay for a second review (the review is a review OF THE
# DIFF, and the diff is the same change).
#
# So there are two questions, answered by two projections of the SAME bytes from
# the SAME normalizer (scripts/lib/diff-normalize.py):
#   * the BINDING projection (`diff=`, cross-repo contract) — unchanged here;
#   * the PATCH projection (`--patch-only`) — drops exactly the three fields a
#     rebase rewrites (blob ids, hunk line numbers, hunk CONTEXT) and keeps
#     everything else BYTE-EXACT, including whitespace and the file PATH.
#
# ⛔ WHY NOT `git patch-id --stable`, which #1377's own text names: `--stable`
# "ignores all whitespace within the patch" (git-patch-id(1)), so a
# whitespace-only edit would match its parent — the exact false ACCEPT #1362 D1
# ruled out. This projection carries both of D1's objections forward (sha256,
# whitespace-exact, and paths included, which patch-id does not commit to)
# instead of reversing the ruling.
#
# ⛔ THE ANCHOR IS WHAT MAKES IT SOUND. A patch match ALONE proves nothing: it
# would let a body-supplied sha pair with any diff. So `patch_dimension_carry`
# requires the reviewed diff it RECONSTRUCTS to normalize to the marker's own
# signed `diff=` before it compares a single changed line. The marker is
# HMAC-verified by the caller (#784) and the reconstruction must reproduce it —
# so the bytes compared are the bytes that marker was minted over. Any mismatch
# (a moved merge-base, a divergence between GitHub's renderings, a rewritten
# reviewed commit) is a REFUSAL, never a guess.
#
# ⛔ IT CANNOT WEAKEN HEAD BINDING. Nothing here mints or accepts a marker: the
# carry RE-RECORDS at the CURRENT head with that head's own `diff=`, exactly as
# the #2982 arm does, so the gate still sees a marker bound to the revision that
# would merge (#930 adversarial class 1). A stale marker over a DIFFERENT patch
# stays refused by both the byte-identity arm and this one.
diff_identity_pair() { # <diff-file> -> "<binding-digest>\t<patch-digest>" ; rc 1 = uncomputable
  local f="$1" t="" a="" p=""
  [ -s "$f" ] || return 1
  # A body with no entry boundary is NOT a diff. Hashing it would mint an
  # identity for bytes nobody reviewed — the same rule the API path applies
  # (#1398). Tested FIRST, so a real diff is never demoted.
  command grep -qE '^diff --git ' "$f" 2>/dev/null || return 1
  command -v python3 >/dev/null 2>&1 || return 1
  command -v openssl >/dev/null 2>&1 || return 1
  [ -f "$DIFF_NORMALIZER" ] && [ -s "$DIFF_NORMALIZER" ] || return 1
  t="$(command mktemp 2>/dev/null)" || return 1
  # `[ -s ]` on the projection OUTPUT, not just its exit status: a zero-byte
  # normalizer exits 0 and prints nothing, and sha256("") is a CONSTANT that
  # would make every diff identical (the #1362 fail-open this file already
  # guards elsewhere). Empty output ⇒ refuse, never hash it.
  a="$(command python3 "$DIFF_NORMALIZER" < "$f" 2>/dev/null > "$t" && [ -s "$t" ] \
        && command openssl dgst -sha256 < "$t" | command awk '{print $NF}')" || a=""
  p="$(command python3 "$DIFF_NORMALIZER" --patch-only < "$f" 2>/dev/null > "$t" && [ -s "$t" ] \
        && command openssl dgst -sha256 < "$t" | command awk '{print $NF}')" || p=""
  command rm -f "$t"
  case "$a$p" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#a}" -eq 64 ] && [ "${#p}" -eq 64 ] || return 1
  printf '%s\t%s\n' "$a" "$p"
  return 0
}
# ── CARRY PROVENANCE HELPERS (#10177) ─────────────────────────────────────
# Two digests a carried record must be able to report about itself: the artifact
# AS REVIEWED, and the delta the head added beyond it. Both are computed from the
# COMMITS (never from a body), through the SAME normalizer the binding uses, so
# the numbers in the record are comparable with `diff_sha256`.
carry_local_artifact_digest() { # <base-sha> <head-sha> -> binding digest of base...head (local)
  local base="$1" head="$2" tmp="" pair=""
  case "$base$head" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#base}" -eq 40 ] && [ "${#head}" -eq 40 ] || return 1
  command git cat-file -e "$head^{commit}" 2>/dev/null || return 1
  tmp="$(command mktemp 2>/dev/null)" || return 1
  if command git diff --no-color --no-ext-diff --no-renames "$base...$head" > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ] && command grep -qE '^diff --git ' "$tmp" 2>/dev/null; then
    if pair="$(diff_identity_pair "$tmp")"; then
      command rm -f "$tmp"
      printf '%s' "${pair%%$'\t'*}"
      return 0
    fi
  fi
  command rm -f "$tmp"
  return 1
}
carry_delta_digest() { # <from-sha> <to-sha> -> binding digest of the tree delta, rc 1 = uncomputable
  local from="$1" to="$2" tmp="" pair=""
  case "$from$to" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#from}" -eq 40 ] && [ "${#to}" -eq 40 ] || return 1
  command git cat-file -e "$from^{commit}" 2>/dev/null || return 1
  command git cat-file -e "$to^{commit}" 2>/dev/null || return 1
  tmp="$(command mktemp 2>/dev/null)" || return 1
  if command git diff --no-color --no-ext-diff --no-renames "$from" "$to" > "$tmp" 2>/dev/null \
     && [ -s "$tmp" ]; then
    if pair="$(diff_identity_pair "$tmp")"; then
      command rm -f "$tmp"
      printf '%s' "${pair%%$'\t'*}"
      return 0
    fi
  fi
  command rm -f "$tmp"
  return 1
}

# #1377 — carry across a head move whose PATCH is unchanged even though the
# BINDING moved. Both sides are READ FRESH from the compare endpoint at the SAME
# base, so the two renderings are the same generator's and the verdict cannot
# depend on when the recorded side happened to be fetched (a TOCTOU the byte-
# identity arm has by construction). This is the arm that carries a REBASE.
patch_dimension_carry() { # <reviewed-sha> <reviewed-binding-digest> <current-head> -> 0 = patch unchanged
  local reviewed="$1" anchor="$2" current="$3" base="" tmp="" pair="" on="" op=""
  [ -n "$reviewed" ] && [ -n "$anchor" ] && [ -n "$current" ] || return 1
  case "$reviewed$anchor$current" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#reviewed}" -eq 40 ] && [ "${#anchor}" -eq 64 ] && [ "${#current}" -eq 40 ] || return 1
  [ -n "$REPO" ] && command -v gh >/dev/null 2>&1 || return 1
  [ "$reviewed" != "$current" ] || return 1
  # THE BASE IS THE API'S (as in lane_dimension_carry): a local ref can LIE about
  # it, and a stale one would make a commit the review never saw look like base
  # content. Same read, same reason, same authority.
  base="$(command gh api "repos/$REPO/pulls/$PR" --jq .base.sha 2>/dev/null || true)"
  case "$base" in *[!0-9a-f]*) return 1 ;; esac
  [ "${#base}" -eq 40 ] || return 1
  tmp="$(command mktemp 2>/dev/null)" || return 1
  # ---- THE REVIEWED SIDE, reconstructed from the marker's own `@ <sha>` ----
  # Three-dot, so the merge-base with the CURRENT base is what is diffed: for a
  # head that was never itself rebased this reproduces the diff the review saw
  # even after the base moved (which is why the ANCHOR below can match).
  if ! command gh api -H "Accept: application/vnd.github.v3.diff" \
         "repos/$REPO/compare/${base}...${reviewed}" > "$tmp" 2>/dev/null \
     || [ ! -s "$tmp" ] \
     || ! command grep -qE '^diff --git ' "$tmp" 2>/dev/null; then
    command rm -f "$tmp"; return 1
  fi
  pair="$(diff_identity_pair "$tmp")" || { command rm -f "$tmp"; return 1; }
  on="${pair%%$'\t'*}"
  op="${pair#*$'\t'}"
  # ---- THE ANCHOR (load-bearing): these bytes ARE the reviewed artifact ----
  # A mismatch means the reconstruction is NOT what the marker was minted over
  # (a moved merge-base, a rewritten reviewed commit, GitHub rendering the two
  # endpoints differently). Refuse — never compare a patch against bytes of
  # unknown provenance.
  if [ "$on" != "$anchor" ]; then command rm -f "$tmp"; return 1; fi
  # ---- THE LIVE SIDE, same base, same generator ----
  if ! command gh api -H "Accept: application/vnd.github.v3.diff" \
         "repos/$REPO/compare/${base}...${current}" > "$tmp" 2>/dev/null \
     || [ ! -s "$tmp" ] \
     || ! command grep -qE '^diff --git ' "$tmp" 2>/dev/null; then
    command rm -f "$tmp"; return 1
  fi
  pair="$(diff_identity_pair "$tmp")" || { command rm -f "$tmp"; return 1; }
  command rm -f "$tmp"
  # ---- THE DECISION: every reviewed changed line, byte for byte, same paths ----
  [ "${pair#*$'\t'}" = "$op" ] || return 1
  return 0
}
# Tier selector, read-only seam. Exits BEFORE the diff-hash fetch and every
# write, so asking "which tier does this diff earn?" costs one compare read and
# can never mint, mutate or carry a record. `ok` is the only status a caller may
# act on; every other status carries an EMPTY tier, so a degraded read is never
# mistaken for a selection.
if [ "$PRINT_TIER" -eq 1 ]; then
  if [ -z "$REPO" ] || ! command -v gh >/dev/null 2>&1; then
    printf 'unavailable\t\n'; exit 0
  fi
  TIER_RC_T=0
  ROWS_T="$(review_surface_rows "$REPO" "$PR" "")" || TIER_RC_T=$?
  case "$TIER_RC_T" in
    0) ;;
    2) printf 'empty\t\n'; exit 0 ;;
    3) # The API ANSWERED with an unusable payload: positive evidence, no tier.
       printf 'unclassified\t\n'; exit 0 ;;
    *) printf 'unavailable\t\n'; exit 0 ;;
  esac
  TIER_HEAD_T="${ROWS_T%%$'\n'*}"
  if [[ "$ROWS_T" == *$'\n'* ]]; then TIER_ROWS_T="${ROWS_T#*$'\n'}"; else TIER_ROWS_T=""; fi
  IFS=$'\t' read -r _tag_t _mb_t TIER_COUNT_T <<< "$TIER_HEAD_T"
  # Truncation guard, same ceiling and same reason as clean_low_shape_ok: the
  # compare endpoint returns at most 300 entries and does NOT paginate, so AT the
  # cap the list may be short — and a short list could be missing the one rail
  # path that would have selected `full`. Report `too_large` (an EMPTY tier), not
  # a tier chosen from a list that may be incomplete.
  #
  # The count is over the NEW path only, exactly as clean_low_shape_ok counts it
  # (its DISTINCT `$2` count, :548) — GitHub counts a rename as ONE changed file while the compare row
  # carries the old path too, so counting both ends would report truncation for
  # any diff containing a rename. The CLASSIFICATION below still reads BOTH ends
  # (a rename out of a rail must not slip through); only the parity arithmetic is
  # path-identity, not path-instance.
  TIER_DISTINCT_T="$(LC_ALL=C awk -F '\t' 'NF>=2 && $2 != "" { print $2 }' <<< "$TIER_ROWS_T" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
  if [ -z "$TIER_DISTINCT_T" ] || [ "$TIER_DISTINCT_T" -eq 0 ]; then
    printf 'empty\t\n'; exit 0
  fi
  if [ "$TIER_DISTINCT_T" -ge 300 ] || [ "$TIER_DISTINCT_T" != "$TIER_COUNT_T" ]; then
    printf 'too_large\t\n'; exit 0
  fi
  if ! CAP_T="$(printf '%s\n' "$TIER_ROWS_T" | review_tier_cap)"; then
    printf 'unclassified\t\n'; exit 0
  fi
  printf 'ok\t%s\n' "$CAP_T"
  exit 0
fi

if [ -n "$REPO" ] && [ "$RECOVER_BODY" -eq 0 ]; then
  # --recover-body (#2872) takes its diff digest from the SIGNED MARKER it
  # verifies, so fetching the PR's live diff here would be a network call whose
  # answer nothing reads — and a failed fetch would print a "could not compute"
  # warning about a mode that does not compute it.
  diff_hash_for_pr "$PR"
  [[ "$DIFF_HASH" =~ ^[0-9a-f]{64}$ ]] || DIFF_HASH=""
  [[ "$LEGACY_DIFF_HASH" =~ ^[0-9a-f]{64}$ ]] || LEGACY_DIFF_HASH=""
  if [ -z "$DIFF_HASH" ]; then
    case "$DIFF_FETCH" in
      empty)
        # A 2xx with no bytes IS a statement about the diff, so it is neither
        # retried nor described as a network failure (#1577).
        echo "⚠️ #2982: could not compute this PR's diff hash — the API answered and the diff body was EMPTY (0 bytes). Recording a legacy sha-only marker; it will NOT carry across a branch update" >&2 ;;
      too_large)
        # #1398 — STRUCTURAL, not a tooling fault. The old wording ("gh/API/openssl
        # unavailable") sent an operator chasing a phantom auth problem for a PR
        # that is simply too large; openssl (LibreSSL 3.3.6) and gh (2.97.0) were
        # both present and working when it reproduced 3-of-3. Retrying cannot help:
        # an idempotent GET answers the same 406.
        echo "⚠️ #2982/#1398: could not compute this PR's diff hash — the PR EXCEEDS GITHUB'S DOCUMENTED 300-FILE DIFF CAP (HTTP 406, code 'too_large'), and no local checkout could mint the digest (needed ${LOCAL_DIFF_REPO:-.} to be a clone of $REPO holding both the base and head commits). This is STRUCTURAL, NOT a tooling/gh/openssl fault, and RETRYING WILL NOT HELP. Recording a legacy sha-only marker, which will NOT carry across a branch update — so this PR becomes unlandable once its base drifts. Remedy: record from a checkout of $REPO that already contains the PR's base and head commits" >&2 ;;
      nondiff)
        # #1398 — a successful HTTP status whose body is not a diff at all. Hashing
        # it would mint an identity for bytes nobody reviewed (an error body), so
        # this refuses rather than guesses.
        echo "⚠️ #2982/#1398: could not compute this PR's diff hash — the API answered with a body that carries NO 'diff --git' entry boundary. Refusing to hash it: a body that is not a diff must NEVER become the reviewed diff. Recording a legacy sha-only marker, which will NOT carry across a branch update" >&2 ;;
      *)
        echo "⚠️ #2982: could not compute this PR's diff hash — the API could not be reached or returned no readable diff (transient: gh auth/network; ${DIFF_FETCH_TRIES} of ${DIFF_FETCH_ATTEMPTS} attempt(s) made). A FAILED FETCH IS NOT A CHANGED ARTIFACT: retry the record before paying for a fresh review. Recording a legacy sha-only marker, which will NOT carry across a branch update" >&2 ;;
    esac
  fi
fi

# #1351 — the read-only consumer seam EXITS here: after the diff read, before
# the stale-sha guard and every write. `ok` is the only status a consumer may
# act on, and every non-ok status is paired with an EMPTY hash — so a degraded
# or refused fetch can never be mistaken for a digest, and a caller that ignores
# the status still finds nothing to compare. The hash is the SAME normalized
# digest the record path stores, and the SAME one the GitHub
# ai-review-gate computes live — one definition of "unchanged".
if [ "$PRINT_DIFF_HASH" -eq 1 ]; then
  printf '%s\t%s\n' "${DIFF_FETCH:-unavailable}" "${DIFF_HASH:-}"
  exit 0
fi

# ── --check-carry: THE LANE'S QUESTION, ANSWERED BY THE GATE'S OWN PREDICATE ──
# #1351. `extensions/review-enforcer` already carries a record across a base move
# when the recorded `diff_sha256` equals the PR's LIVE normalized three-dot diff.
# Nothing told a LANE that, so lanes inferred "the branch moved, therefore the
# review is stale" and paid for a fresh 20-40 minute review — re-minting records
# after every base move, which is how a fleet reaches a dozen blocked PRs while
# the content never changed.
#
# This is the ONE way to ask. It deliberately adds NO second definition of
# "unchanged": it runs `diff_hash_for_pr` (the single normalizer the record path
# and the GitHub gate share) and compares that digest to the record's field with
# the same validity rule the local gate uses (full lowercase 64-hex, never the
# empty-body constant). A second hashing path — or a second rule for what counts
# as an identity — is exactly what this design avoids.
#
# ⛔ IT IS READ-ONLY AND IT CANNOT MAKE A RECORD VALID. It prints what the GATE
# would decide; the gate re-decides at merge time, and an unreadable diff is
# NEVER reported as a carry (see the status arm below).
if [ "$CHECK_CARRY" -eq 1 ]; then
  # #3315 — WHICH RECORD THIS QUESTION IS ABOUT. Default: this box's record FILE
  # (the WRITER's own convention, below). A caller that supplies --recorded-diff
  # names the pair EXPLICITLY instead — the arm check-pipeline-compliance.sh's
  # check (c) uses on a CI runner, which has no $HOME/.pi/agent/reviews but does
  # have the PR body's marker. ONE predicate, one identity rule, one answer; the
  # source is recorded in CC_ORIGIN so diagnostics can say which one decided.
  # The record path is the WRITER's own convention (see DIR/FILE below), so the
  # reader cannot disagree with the writer. The legacy <pr>.json is honoured
  # only when it names no repo or THIS repo — the #426 collision rule the local
  # gate and admin-merge.sh both apply.
  CC_DIR="$HOME/.pi/agent/reviews"
  CC_FILE=""
  CC_LEGACY=""
  if [ -n "$REPO" ]; then
    CC_FILE="$CC_DIR/${REPO%/*}-${REPO#*/}-$PR.json"
    CC_LEGACY="$CC_DIR/$PR.json"
  else
    # NO REPO: the legacy <pr>.json is the ONLY name known in advance — a qualified
    # record cannot be derived without the repo, so it is discovered by SCAN below
    # (exactly what the gate does). Using CC_FILE for it made the no-repo path
    # believe the legacy file WAS the qualified one.
    CC_FILE=""
    CC_LEGACY="$CC_DIR/$PR.json"
  fi
  # `|| true` is load-bearing: `head -1` closes the pipe, and under this script's
  # `set -uo pipefail` a sed killed by SIGPIPE makes the whole pipeline 141 — which,
  # under `set -e`, would abort the mode on a record it had merely finished reading
  # (the same SIGPIPE flake class the test suite shows intermittently under load).
  cc_field() { # <file> <field>
    command sed -n "s/.*\"$2\":\"\\([^\"]*\\)\".*/\\1/p" "$1" 2>/dev/null | command head -1 || true
  }
  # #3400 — NUMERIC fields (`findings`) are written WITHOUT quotes, so `cc_field`
  # cannot read them. A second pattern, not a loosened first one: `cc_field` is
  # shared with the head/diff/verdict reads whose quoting IS the contract.
  cc_num_field() { # <file> <field>
    command sed -n "s/.*\"$2\":\\([0-9][0-9]*\\).*/\\1/p" "$1" 2>/dev/null | command head -1 || true
  }
  # ⛔ MIRROR THE GATE'S LOOKUP EXACTLY, INCLUDING ITS COLLISION RULE (review, #2353 P1).
  # `extensions/review-enforcer::readReviewRecord` returns NULL when the QUALIFIED file
  # exists but its embedded `repo` differs (the identical-slug overwrite class: PR
  # numbers collide across repos), and it compares `repo` CASE-SENSITIVELY. Reading the
  # qualified file unconditionally made this surface answer `carry … land it` for a
  # record the gate treats as ABSENT — a divergent second definition of "the record",
  # which is the very thing this mode exists to avoid. Both arms now use one predicate,
  # and the comparison is exact: a differently-cased repo is a DIFFERENT key.
  cc_names_this_repo() { # <file> -> 0 when its embedded repo is absent or exactly $REPO
    local r
    r="$(cc_field "$1" repo)"
    [ -z "$r" ] || [ "$r" = "$REPO" ]
  }
  CC_REC=""
  CC_ORIGIN="record file"
  CC_SUPPLIED=0
  # ⛔ THE SUPPLIED PAIR SHORT-CIRCUITS THE LOOKUP — it is not merged with the
  # file and it never defers to it. A caller that named a digest is asking about
  # THAT digest; answering from a different record file would recreate exactly
  # the two-readers divergence this mode exists to end. `--recorded-head` may
  # legitimately be absent (a pre-#2982 marker carries no head), which is why only
  # the digest is required: an absent head disables the head arm and the rebase
  # arm, and NO verdict is invented from it.
  if [ -n "$RECORDED_DIFF" ]; then
    CC_SUPPLIED=1
    CC_ORIGIN="caller-supplied record pair"
    CC_HEAD="$RECORDED_HEAD"
    CC_DIFF="$RECORDED_DIFF"
  fi
  if [ "$CC_SUPPLIED" -eq 0 ]; then
  # #2872: the remedy for an ABSENCE is no longer only "review it again". A box
  # that lacks the file may still have the verdict in the registry (minted on a
  # peer box), in the PR body's SIGNED marker, or in an admitted PR comment
  # (minted anywhere; both travel). Naming only the re-review made every cross-box review
  # cost twice — a lane paying again for evidence the fleet already holds.
  CC_LOOKUP_HINT="Run the review, then record it. Before paying for that: if it ran on ANOTHER box, scripts/registry-sync.sh pull may already hold it; and if the PR body carries a SIGNED marker, record-review.sh --recover-body $PR ${REPO:-owner/repo} rebuilds this box's record from it (it verifies the HMAC first, so a body edit cannot mint one)."
  if [ -n "$REPO" ]; then
    if [ -n "$CC_FILE" ] && [ -f "$CC_FILE" ]; then
      if cc_names_this_repo "$CC_FILE"; then CC_REC="$CC_FILE"; fi
    elif [ -n "$CC_LEGACY" ] && [ -f "$CC_LEGACY" ]; then
      if cc_names_this_repo "$CC_LEGACY"; then CC_REC="$CC_LEGACY"; fi
    fi
  else
    # ⛔ THE NO-REPO BRANCH IS A DIFFERENT RULE, NOT A DEGENERATE ONE (review, #2353 P2).
    # `readReviewRecord(pr)` with no repo context cannot derive a qualified name, so it
    # TRUSTS A KEY THAT PROVES ITS REPO: a single uniquely-matching qualified file
    # (<owner>-<repo>-<pr>.json), and NOTHING ELSE — an ambiguous set is a collision, and
    # a legacy file that EMBEDS a repo is rejected (#426 review P0-2: it may be another
    # repo's PR with the same number). This mode read only <pr>.json here, so in the very
    # state it exists for — repo auto-detection failing under a contested gh gate, REPO
    # empty — it told a lane "no record … run the review" about a record the gate reads
    # and would carry: the 20-40 minute re-review, triggered BY the check meant to prevent it.
    CC_MATCHES=()
    for _f in "$CC_DIR"/*-"$PR".json; do
      [ -f "$_f" ] || continue
      CC_MATCHES+=("$_f")
    done
    if [ "${#CC_MATCHES[@]}" -eq 1 ]; then
      CC_REC="${CC_MATCHES[0]}"
    elif [ "${#CC_MATCHES[@]}" -gt 1 ]; then
      CC_LOOKUP_HINT="More than one repo has a record for #$PR (${#CC_MATCHES[@]} files) and no repo was resolved, so the record CANNOT be identified — pass owner/repo: record-review.sh --check-carry $PR owner/repo. (The merge gate treats an ambiguous lookup as NO record, so nothing would carry.)"
    elif [ -n "$CC_LEGACY" ] && [ -f "$CC_LEGACY" ]; then
      if [ -z "$(cc_field "$CC_LEGACY" repo)" ]; then CC_REC="$CC_LEGACY"; fi
    fi
  fi
  if [ -z "$CC_REC" ]; then
    printf 'norecord\t-\t%s\n' "${DIFF_HASH:--}"
    echo "record-review.sh --check-carry: no review record for ${REPO:-<no repo resolved>}#$PR — there is no verdict to carry. $CC_LOOKUP_HINT" >&2
    exit 4
  fi
  CC_HEAD="$(cc_field "$CC_REC" head_sha)"
  CC_DIFF="$(cc_field "$CC_REC" diff_sha256)"
  fi   # end of the record-FILE arm (#3315): a caller-supplied pair skipped it
  # ── #3400 — THE VERDICT THIS RECORD CARRIES, so a NEGATIVE one can be reported ──
  # `--check-carry` answered "may this record carry?" and never said WHAT the
  # record says, so a `not-clean` record carried exactly like a `clean` one and
  # the lane was told "Do NOT re-review … land it" over an open finding. The
  # ANSWER WORD and exit code are unchanged (the seven-verdict contract is
  # consumed positionally by other tools and #3315 pins it) — what is added is
  # the diagnosis the answer was missing: the verdict and the open-finding count.
  # Empty when the pair was CALLER-SUPPLIED (there is no record file to read),
  # and empty reads as "not negative", never as "negative with no count".
  CC_VERDICT=""; CC_FINDINGS=""
  if [ "$CC_SUPPLIED" -eq 0 ]; then
    CC_VERDICT="$(cc_field "$CC_REC" verdict)"
    CC_FINDINGS="$(cc_num_field "$CC_REC" findings)"
  fi
  case "$CC_FINDINGS" in *[!0-9]*) CC_FINDINGS="" ;; esac
  cc_report_negative() { # -> one stderr line naming the negative verdict, or nothing
    [ "${CC_VERDICT:-}" = "not-clean" ] || return 0
    echo "record-review.sh --check-carry: ⛔ reviewed NOT CLEAN at ${CC_HEAD:0:12}…${CC_FINDINGS:+ — $CC_FINDINGS open finding(s)}. This verdict CARRIES across the head move on the same terms a clean one does (the reviewed DIFF is what identity is over), so the CARRY is legitimate — what it carries is 'this has an open issue', NOT a licence to merge. Resolve the finding and record again; the answer below says whether the record still covers what would merge, not whether it is clean." >&2
  }
  cc_report_negative
  # ── AN UNPROVEN CARRY IS NOT A RECORD (#10177) ─────────────────────────────
  # A `mint:"carried"` record re-binds a verdict minted at ANOTHER head onto the
  # live one. That is legitimate only when the record SAYS which proof it used and
  # keeps the artifact it was carried from — otherwise nothing distinguishes
  # "the reviewed artifact was provably unchanged" from "someone re-ran the
  # recorder at a stale head". The measured instance (tortoise#10677, 2026-11-03)
  # carried a `clean` verdict from 004d5afa4 onto f8842dc7e — 4 files, +178/−18 —
  # with `carry_arm` absent and `evidence` absent: it asserted coverage of a tree
  # nothing reviewed, and no reader (this mode included) could tell. Such a record
  # does NOT cover the live head, so the answer here is `norecord` — what a reader
  # can act on — never `head`.
  CC_MINT="$(cc_field "$CC_REC" mint)"
  # ⛔ A `mint:"delta"` RECORD IS A CARRY TOO (#10583 × #10177). `--delta` re-binds a
  # verdict minted at ANOTHER head exactly as a `carried` record does; the only difference
  # is how the reviewed head was FOUND (read from the record instead of passed in).
  # Exempting it would reopen the hole #10177 closed — a reader could not tell a delta that
  # PROVED the artifact unchanged from one that merely asserted it — so it is held to the
  # same proof: the arm that proved it, and the review artifact the verdict rests on.
  # (Records minted by an earlier revision of the delta verb predate `carry_arm`/`evidence`
  # and are caught by exactly this rule, which is why the rule must not be mint-specific.)
  case "${CC_MINT:-}" in
  carried|delta)
    CC_ARM_F="$(cc_field "$CC_REC" carry_arm)"
    CC_EV_F="$(cc_field "$CC_REC" evidence)"
    if [ -z "$CC_ARM_F" ] || [ -z "$CC_EV_F" ]; then
      printf 'norecord\t-\t%s\n' "${DIFF_HASH:--}"
      echo "record-review.sh --check-carry: the record at ${CC_HEAD:0:12}… is a CARRY with NO recorded proof (mint='${CC_MINT}', carry_arm='${CC_ARM_F:-}', evidence='${CC_EV_F:-}') — it asserts a verdict minted at another head without recording which arm proved the artifact unchanged, or what review artifact it rests on. Nothing in it shows it covers the head that would merge, so it is treated as NO RECORD (the shape tortoise#10677 produced: a clean verdict carried across 4 files/+178 with no provenance). Remedy: re-record at the current head and let the recorder's carry arms decide — they refuse when the reviewed artifact moved, and record the proof when it did not: record-review.sh $PR <current head> <same verdict> ${REPO:-owner/repo}" >&2
      exit 4
    fi ;;
  esac
  # The gate's own identity rule (isDiffSha256 in extensions/review-enforcer):
  # full lowercase 64-hex, and NEVER the sha256 of the empty body — that constant
  # would make every record "match" every PR.
  cc_is_identity() {
    case "$1" in
      *[!0-9a-f]*) return 1 ;;
    esac
    [ "${#1}" -eq 64 ] || return 1
    [ "$1" != "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855" ] || return 1
    return 0
  }
  # The CURRENT head, read-only. A read failure is UNKNOWN, never a mismatch: the
  # whole point of this mode is to stop rendering "could not read" as "changed".
  # Same read (and same idiom) as the stale-sha guard below, so one fixture models
  # both and the two can never disagree about which head is current.
  CC_LIVE_HEAD="$(command gh api "repos/$REPO/pulls/$PR" --jq .head.sha 2>/dev/null || true)"
  case "$CC_LIVE_HEAD" in
    *[!0-9a-f]* | "") CC_LIVE_HEAD="" ;;
  esac
  if [ "${#CC_LIVE_HEAD}" -ne 40 ]; then CC_LIVE_HEAD=""; fi
  # HEAD BINDING FIRST: a record at the CURRENT head is valid with no digest at
  # all, and that is the commonest healthy case — it must not read as "carry".
  # (An EMPTY recorded head — a supplied pair with no --recorded-head — is UNKNOWN
  # and cannot equal a live head, so the comparison below already refuses it; no
  # extra guard is needed and none is claimed.)
  if [ -n "$CC_LIVE_HEAD" ] && [ "$CC_HEAD" = "$CC_LIVE_HEAD" ]; then
    printf 'head\t%s\t%s\n' "${CC_DIFF:--}" "${DIFF_HASH:--}"
    echo "record-review.sh --check-carry: the record is bound to the CURRENT head (${CC_HEAD:0:12}…) — nothing is stale and nothing needs re-review." >&2
    exit 0
  fi
  # ⛔ ORDER: THE ANSWER THAT NEEDS NO READ COMES FIRST (review, #2353 P2). A record
  # with no usable digest can NEVER carry, and that is decidable from the record alone —
  # so putting it after the diff-read arm made it unreachable exactly when the gate is
  # contended (every attempt returned `unreadable`/RETRY forever, while the guidance
  # that unsticks the lane needs no read at all). Neither branch is reachable from
  # `carry`, so the swap weakens nothing.
  if ! cc_is_identity "$CC_DIFF"; then
    printf 'nodigest\t-\t%s\n' "${DIFF_HASH:--}"
    # ⛔ THE REMEDY MUST BE RUNNABLE IN THE STATE THAT FIRES IT (review, #2353 round 4).
    # Printing `… $REPO` with REPO empty promised a carry that CANNOT exist: the recorder's
    # carry arms verify identity by computing the diff, which needs the repo, so the advised
    # command refuses and names "→ Run the review" — the 20-40 minute path this mode exists
    # to avoid — and re-running --check-carry answers `nodigest` again, so the advice cannot
    # converge. With no repo the command is not merely incomplete, it is the wrong command,
    # so say what is missing instead of printing an empty slot.
    if [ -n "$REPO" ]; then
      echo "record-review.sh --check-carry: the record at ${CC_HEAD:0:12}… carries no usable diff digest (a legacy record, or one minted while the diff read was degraded), so it cannot carry on content identity. Re-run the recorder at the current head and let its carry arms decide: record-review.sh $PR <current head> <same verdict> $REPO — that is a CARRY, not a fresh review, and it refuses if the lane's commits changed." >&2
    else
      echo "record-review.sh --check-carry: the record at ${CC_HEAD:0:12}… carries no usable diff digest (a legacy record, or one minted while the diff read was degraded), so it cannot carry on content identity — and NO repo was resolved here, so the recorder's carry arms cannot compute the identity that would let it. Pass it explicitly: record-review.sh $PR <current head> <same verdict> owner/repo — that is a CARRY, not a fresh review, and it refuses if the lane's commits changed." >&2
    fi
    exit 5
  fi
  # ⛔ AN UNREADABLE DIFF IS NEVER A CARRY. Every non-ok status means the diff
  # could not be READ, and a failed read is not a matching read.
  if [ "${DIFF_FETCH:-unavailable}" != "ok" ] || ! cc_is_identity "${DIFF_HASH:-}"; then
    printf 'unreadable\t%s\t%s\n' "$CC_DIFF" "${DIFF_FETCH:-unavailable}"
    echo "record-review.sh --check-carry: the PR's live diff could not be READ (status ${DIFF_FETCH:-unavailable}) — this is NOT a changed diff and NOT a carry. RETRY (a shared gh-gate queue, a rate-limit window or a transient API failure is far cheaper than a re-review)." >&2
    exit 3
  fi
  if [ "$CC_DIFF" = "$DIFF_HASH" ]; then
    printf 'carry\t%s\t%s\n' "$CC_DIFF" "$DIFF_HASH"
    echo "record-review.sh --check-carry: the reviewed DIFF is UNCHANGED (diff_sha256 ${CC_DIFF:0:12}… matches the PR's live diff) — the merge gate CARRIES this record across the head move (${CC_HEAD:-the earlier head}${CC_HEAD:+ }…). Do NOT re-review and do NOT mint a fresh record: land it. [source: $CC_ORIGIN]" >&2
    exit 0
  fi
  # ── #1377 — `carry-patch`: the BINDING moved, the PATCH did not ────────────
  # The arm above is byte-identity of the rendered diff. A REBASE onto a moved
  # base rewrites hunk context even when no reviewed line changed, so the
  # binding moves and this mode used to answer `fresh` — the 20-40 minute
  # re-review #1351 exists to prevent, demanded for work that did not change.
  # The predicate is the RECORDER's own arm, not a second definition: if it
  # says so, `record-review.sh <pr> <current head> <same verdict> <repo>`
  # carries without a review. The token is DISTINCT from `carry` and exit is
  # NOT 0 because the gate does not carry this one — the record must be
  # re-minted, and a caller that read exit 0 as "merge it" would be wrong.
  if patch_dimension_carry "$CC_HEAD" "$CC_DIFF" "$CC_LIVE_HEAD"; then
    printf 'carry-patch\t%s\t%s\n' "$CC_DIFF" "$DIFF_HASH"
    echo "record-review.sh --check-carry: the reviewed PATCH is unchanged (the rendered diff moved, so the merge gate will NOT carry this record as-is — but every reviewed line is byte-identical at ${CC_HEAD:0:12}… and ${CC_LIVE_HEAD:0:12}…). This is a rebase/base-move, NOT a changed artifact: re-record at the current head — record-review.sh $PR $CC_LIVE_HEAD <same verdict> ${REPO:-<owner/repo>} — do NOT run a review cycle." >&2
    exit 6
  fi
  printf 'fresh\t%s\t%s\n' "$CC_DIFF" "$DIFF_HASH"
  echo "record-review.sh --check-carry: the DIFF CHANGED (recorded ${CC_DIFF:0:12}… vs live ${DIFF_HASH:0:12}…) — the record genuinely does not cover what would merge. Run the code-review skill, post its verdict as a PR comment, then record clean with --evidence comment:<id>." >&2
  exit 1
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

# ── --recover-body (#2872): rebuild a MISSING record from the SIGNED marker ──
# The record file is per-box; a signed marker in the PR body OR in an admitted PR
# comment travels. So an absence on THIS box is not evidence that no
# review happened — and the rail's only named remedy ("run the review") makes a
# lane pay a second time for a verdict the fleet already holds (#2872: 12 of 45
# open PRs, of which the registry covered 2).
#
# ⛔ THE HMAC IS THE WHOLE SAFETY ARGUMENT. A PR body is attacker-writable, so a
# marker is EVIDENCE only when its `sig=` verifies over its own text with the
# gate key — the same check the carry-forward arm makes (#784/#2055) and for the
# same reason: a shape-only `[0-9a-f]{64}` match accepts `sig=<64 zeros>`, which
# a later carry would then RE-SIGN with the real key, minting a genuine
# attestation for a diff nobody reviewed. Unsigned, forged, or foreign-repo
# markers are REFUSED and named; nothing is written.
#
# This verb cannot loosen the gate. What it restores is (pr, head_sha,
# diff_sha256, verdict) — the SAME fields a normal record holds — and every
# downstream decision (`--check-carry`, the merge rail, the GitHub gate) re-reads
# them the same way. A recovered record whose digest no longer matches the PR's
# live diff still answers `fresh`, so a moved diff still owes a review.
if [ "$RECOVER_BODY" -eq 1 ]; then
  # REPO was auto-detected above (the recorder's ONE resolution path), so this
  # mode never re-derives it: a second detector would be a second answer.
  if [ -z "$REPO" ]; then
    echo "record-review.sh --recover-body: no repo resolved. A record is identified by PR *and* repo (PR numbers collide across repos), so pass it: record-review.sh --recover-body $PR owner/repo" >&2
    exit 2
  fi
  if [ -z "$GATE_KEY" ]; then
    echo "record-review.sh --recover-body: AI_REVIEW_GATE_KEY is not configured (env or ~/.pi/agent/.ai-review-gate-key), so a marker's signature cannot be VERIFIED — and an unverified marker is a body edit, not evidence. Refusing rather than minting on trust." >&2
    exit 3
  fi
  RB_FILE="$HOME/.pi/agent/reviews/${REPO%/*}-${REPO#*/}-$PR.json"
  RB_LEGACY="$HOME/.pi/agent/reviews/$PR.json"
  # ⛔ RECOVERY FILLS AN ABSENCE; IT NEVER REPLACES. An existing record may be
  # NEWER than the marker (a later review, a carry already re-bound), and
  # overwriting it with an older verdict would silently walk the gate backwards.
  #
  # WHICH FILES COUNT AS "A RECORD FOR THIS PR" is the GATE's rule, not a
  # filename test (review, #2872 P2): `readReviewRecord` treats a file whose
  # embedded `repo` DIFFERS as ABSENT — so a bare `[ -f ]` here would refuse on a
  # file the rail does not see, and the caller would be told to run
  # `--check-carry`, which answers `norecord` and points back here: a closed loop
  # whose only exit is a paid re-review. An UNQUALIFIED (`<pr>.json`) or
  # repo-less file is still refused, because there is no way to prove it is not
  # this PR, and deleting/overwriting it could destroy another repo's only copy.
  rb_names_this_repo() { # <file> -> 0 when its embedded repo is absent or exactly $REPO
    local r
    r="$(command sed -n 's/.*"repo":"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | command head -1)"
    [ -z "$r" ] || [ "$r" = "$REPO" ]
  }
  rb_existing_record() { # -> 0 when a record for THIS PR/repo already exists
    [ -f "$RB_FILE" ] && rb_names_this_repo "$RB_FILE" && return 0
    [ -f "$RB_LEGACY" ] && rb_names_this_repo "$RB_LEGACY" && return 0
    return 1
  }
  # ⛔ "NOTHING TO REPAIR" IS A CLAIM ABOUT A PARSEABLE RECORD (round 2, P2). A
  # TRUNCATED/corrupt file parses to no `repo` string, which rb_names_this_repo
  # reads as "unowned" — so the refusal below would assert there is nothing to
  # repair about a file the GATE calls `corrupt`/NO-RECORD (and whose own message
  # now points here). That is the round-1 loop shape in a different state.
  rb_record_usable() { # <file> -> 0 when it carries the fields a record is read by
    # ⛔ FORMAT-AGNOSTIC, LIKE THE GATE (round 3, P2). This greps the COMPACT form
    # the recorder writes; the gate JSON-parses the file, so a `jq .` round-trip
    # (the literal "hand-edited file") is a VALID record to the gate. Reading it as
    # unusable would then tell an operator to move aside a record the gate is
    # honouring — and recovery would mint an OLDER verdict over it.
    if command -v jq >/dev/null 2>&1; then
      # ⛔ THE GATE REQUIRES STRINGS, NOT MERE PRESENCE (round 4, P3):
      # `readRecordFile` tests `typeof === "string"`, so `"head_sha": null` is
      # ABSENT to the gate. A bare `has()` would call that file a record here and
      # answer "already exists, nothing to repair" for one the rail says NO-RECORD
      # about — the round-2 loop, narrowed to a present-but-untyped key.
      command jq -e '(.head_sha|type)=="string" and (.verdict|type)=="string"' "$1" >/dev/null 2>&1 && return 0
      return 1
    fi
    grep -q '"head_sha"' "$1" 2>/dev/null && grep -q '"verdict"' "$1" 2>/dev/null
  }
  rb_foreign_repo_of() { # <file> -> the embedded repo, or empty
    command sed -n 's/.*"repo":"\([^"]*\)".*/\1/p' "$1" 2>/dev/null | command head -1
  }
  rb_refuse_foreign() { # <file> — exit 5, naming the file and a NON-LOOPING remedy
    echo "record-review.sh --recover-body: ${1/#$HOME/~} already exists but embeds repo $(rb_foreign_repo_of "$1") — the identical-slug overwrite state, which the merge gate reads as ABSENT. Refusing to overwrite another repo's verdict. Move that file aside (it lives outside any checkout: mv it, or let its owning repo's registry-sync restore it) and re-run this command; nothing was written." >&2
    exit 5
  }
  rb_refuse_unusable() { # <file> — exit 5, naming it as not-a-record and a way out
    echo "record-review.sh --recover-body: ${1/#$HOME/~} exists but is NOT a usable record — it carries no readable head_sha/verdict (a truncated or malformed file), so the merge gate treats it as ABSENT and 'there is nothing to repair here' would be false. If the gate CAN read it (a valid record some other writer formatted differently), LEAVE IT — this verb will not overwrite one; otherwise move it aside and re-run. Nothing was written." >&2
    exit 5
  }
  if [ -f "$RB_FILE" ]; then
    if ! rb_names_this_repo "$RB_FILE"; then rb_refuse_foreign "$RB_FILE"; fi
    if ! rb_record_usable "$RB_FILE"; then rb_refuse_unusable "$RB_FILE"; fi
  fi
  if [ -f "$RB_LEGACY" ] && rb_names_this_repo "$RB_LEGACY" && ! rb_record_usable "$RB_LEGACY"; then
    rb_refuse_unusable "$RB_LEGACY"
  fi
  if rb_existing_record; then
    echo "record-review.sh --recover-body: a record for $REPO#$PR already exists ($( [ -f "$RB_FILE" ] && echo "${RB_FILE/#$HOME/~}" || echo "${RB_LEGACY/#$HOME/~}" )) — recovery fills an ABSENCE and will not replace it. There is nothing to repair here; land it, or if the diff has moved since, ask what the gate thinks: record-review.sh --check-carry $PR $REPO" >&2
    exit 5
  fi
  # ⛔ A PERMANENT FAILURE IS NOT A TRANSIENT ONE (round 3, P2). Both reads below
  # used to say "RETRY" for every non-zero exit — so a 404 (wrong PR number, or a
  # repo this token cannot see) sent a lane round a loop that can never converge.
  # The rest of this file is careful about exactly this (#1398: an operator sent
  # chasing a phantom auth problem), so the error TEXT is captured and branched on.
  rb_is_permanent_gh_error() { # <captured stderr/stdout> -> 0 when retrying cannot help
    case "$1" in
      *"Not Found"*|*"HTTP 404"*|*"status 404"*|*"HTTP 422"*|*"status 422"*|*"No commit found"*) return 0 ;;
    esac
    return 1
  }
  if ! RB_BODY="$(command gh api "repos/$REPO/pulls/$PR" --jq .body 2>&1)"; then
    if rb_is_permanent_gh_error "$RB_BODY"; then
      echo "record-review.sh --recover-body: the PR could not be read and retrying will NOT help — gh said: $(printf '%s' "$RB_BODY" | command head -1 | cut -c1-160). Check the owner/repo argument and the PR number (a PR this token cannot see reads exactly like a missing one). Nothing was written." >&2
    else
      echo "record-review.sh --recover-body: could not READ the PR body (transient API failure?) — that is not 'no marker'. RETRY; nothing was written." >&2
    fi
    exit 3
  fi
  [ "$RB_BODY" = "null" ] && RB_BODY=""
  # The marker contract is fixed by the poster and read by the upstream required
  # check (tortoise .github/workflows/ai-review-gate.yml): keep it EXACT — the
  # verdict is one of the three record tiers, the head is a full 40-hex, and the
  # optional `diff=` is a full 64-hex digest.
  RB_LINE=""; RB_SIG=""; RB_TEXT=""; RB_NBAD=0; RB_NFOREIGN=0
  while IFS= read -r _line; do
    case "$_line" in
      "review recorded: reviews/$PR.json verdict="*) ;;
      *) continue ;;
    esac
    # `(<repo>) sig=<64hex>` — the sig covers EVERYTHING before ' sig=', which is
    # why the split is on that exact token rather than on whitespace.
    case "$_line" in
      *" sig="*) ;;
      *) RB_NBAD=$((RB_NBAD + 1)); continue ;;
    esac
    _text="${_line% sig=*}"
    _sig="${_line##* sig=}"
    [[ "$_sig" =~ ^[0-9a-f]{64}$ ]] || { RB_NBAD=$((RB_NBAD + 1)); continue; }
    # ⛔ THE REGEX IS HELD IN A VARIABLE, NOT WRITTEN INLINE. Inside `[[ … ]]` a
    # bare `(` starts a grouping expression, so an inline ERE with groups is a
    # PARSE error the shell raises when it reaches the enclosing block — even on
    # a run where RECOVER_BODY is 0 (measured: 214 assertions in the suite went
    # red on one unescaped paren, because bash parses the whole `if … fi` when it
    # reaches it). Expanded from a variable, the regex is an ordinary operand.
    # #3400 — the negative family is admitted HERE, and its trailer is part of the
    # pattern. Before this, a `verdict=not-clean` marker fell into RB_NBAD ("a
    # marker whose signature does not verify"), so the ONE body channel that
    # travels across boxes reported a signature failure for a perfectly good
    # marker: presence-based reading that could not even SEE the negative, let
    # alone prefer it. The repo group is UNCHANGED at index 3 — the new
    # findings/note group is appended AFTER it, so no existing read shifts.
    RB_RE="^review recorded: reviews/${PR}\.json verdict=(clean|clean-micro|clean-low|not-clean) @ [0-9a-f]{40}( diff=[0-9a-f]{64})? \(([^)]+)\)( findings=[0-9]+( note=[^\"\\\\]*)?)?$"
    [[ "$_text" =~ $RB_RE ]] || { RB_NBAD=$((RB_NBAD + 1)); continue; }
    [ "${BASH_REMATCH[3]}" = "$REPO" ] || { RB_NFOREIGN=$((RB_NFOREIGN + 1)); continue; }
    # (the HMAC is verified below for THIS repo's marker only, so the foreign-arm
    # message must not claim a signature was checked — see the wording there.)
    _expect="$(printf '%s' "$_text" | command openssl dgst -sha256 -hmac "$GATE_KEY" 2>/dev/null | awk '{print $NF}' || true)"
    if [ -z "$_expect" ] || [ "$_expect" != "$_sig" ]; then
      RB_NBAD=$((RB_NBAD + 1)); continue
    fi
    # Keep the LAST verifying marker: the poster APPENDS, so the newest verdict
    # is the final line appended for this repo ("keep the first" would resurrect
    # a verdict the review itself superseded).
    RB_LINE="$_line"; RB_SIG="$_sig"; RB_TEXT="$_text"
  done <<<"$RB_BODY"
  if [ -z "$RB_LINE" ]; then
    if [ "$RB_NBAD" -gt 0 ]; then
      echo "record-review.sh --recover-body: $REPO#$PR has $RB_NBAD marker line(s) for this PR but NONE whose signature verifies with this box's gate key — a marker whose HMAC does not verify is a body EDIT, not evidence, so nothing was written. (A wrong AI_REVIEW_GATE_KEY, a marker from a differently-keyed repo, or a forged line all present this way.)" >&2
    elif [ "$RB_NFOREIGN" -gt 0 ]; then
      echo "record-review.sh --recover-body: $REPO#$PR has a marker naming a DIFFERENT repo ($RB_NFOREIGN line(s)) and none for $REPO — PR numbers collide across repos, so this is refused rather than adopted. Check the owner/repo argument. (Its signature was NOT checked: this verb only verifies a marker that names the repo it was asked about.)" >&2
    else
      # ⛔ AN ABSENCE OF EVIDENCE IN THIS BODY IS NOT A VERDICT ABOUT THE REVIEW
      # (review, #2872 P2). The evidence post is BEST-EFFORT — the recorder saves
      # the record and skips the post on an API failure — and a body edit can
      # remove a marker. Claiming "no review was ever recorded on any box" would
      # send a lane to pay for a second review that #2872 exists to avoid.
      echo "record-review.sh --recover-body: this PR's body carries no 'review recorded:' marker for $REPO#$PR, so there is nothing HERE to recover — that is not proof no review happened (the evidence post is best-effort, and a body edit removes one). If the review ran on another box, scripts/registry-sync.sh pull may hold it; otherwise run the review and record it." >&2
    fi
    exit 3
  fi
  RB_VERDICT="${RB_TEXT#*verdict=}"; RB_VERDICT="${RB_VERDICT%% *}"
  # #3400 — the negative marker's trailer. Absent for every clean tier, so a
  # recovered clean record is byte-identical to what it was before this change.
  RB_FINDINGS=""; RB_NOTE=""
  case "$RB_TEXT" in
    *" findings="*) RB_FINDINGS="${RB_TEXT#* findings=}"; RB_FINDINGS="${RB_FINDINGS%% *}" ;;
  esac
  case "$RB_TEXT" in
    *" note="*) RB_NOTE="${RB_TEXT#* note=}" ;;
  esac
  # ⛔ CANONICALISE THE COUNT AT **THIS** WRITE TOO (review, P3-5) — the mint's
  # `--findings` canonicaliser exists because the value IS the record's validity:
  # `"findings":$RB_FINDINGS` is written UNQUOTED, because every reader binds a
  # JSON NUMBER (review-enforcer: `typeof record.findings === "number"`). This is
  # the SECOND writer of that field, and it filtered with `*[!0-9]*` ALONE — so the
  # rule the mint holds was never applied here. MEASURED against the previous arm:
  # a signed marker carrying `findings=007` (admissible by RB_RE's `findings=[0-9]+`)
  # recovered to `"findings":007`, which does not parse — `JSONDecodeError`, so the
  # gate reads NO RECORD — and the file now EXISTS, so the next recovery refuses
  # ("a record already exists — recovery fills an ABSENCE"). A dead end needing
  # manual removal, created by the one verb whose job is to avoid a dead end, and
  # therefore strictly worse than the absent record it replaced. `00` was worse
  # still: it wrote `"findings":00` and exited 0, where the mint refuses a zero
  # count outright ('not-clean' with zero findings IS 'clean').
  #
  # Same two steps as the mint, deliberately PURE STRING manipulation (`10#`
  # arithmetic wraps on a pathologically long value): reject non-digits, then strip
  # the leading-ZERO RUN — `007` → `7`, `08` → `8`, `12` → `12`, `00` → empty,
  # which the not-clean arm immediately below refuses rather than writes.
  case "$RB_FINDINGS" in
    *[!0-9]*) RB_FINDINGS="" ;;
    *)
      RB_FINDINGS_ZEROS="${RB_FINDINGS%%[!0]*}"
      RB_FINDINGS="${RB_FINDINGS#"$RB_FINDINGS_ZEROS"}" ;;
  esac
  if [ "$RB_VERDICT" = "not-clean" ] && [ -z "$RB_FINDINGS" ]; then
    echo "record-review.sh --recover-body: $REPO#$PR's marker is a \`not-clean\` attestation but carries no readable \`findings=\` count, so a recovered record could not tell the gate WHAT is open. Nothing was written; mint it again at the current head: record-review.sh $PR <current head> not-clean $REPO --findings <n> --evidence <artifact>" >&2
    exit 3
  fi
  # ⛔ THE HEAD IS READ FROM ITS STRUCTURAL POSITION, NEVER "the last ` @ <40hex>`"
  # (review, P3-2). The previous read was a GREEDY sed — `s/.* @ \([0-9a-f]\{40\}\).*/\1/p`
  # — which takes the LAST ` @ ` followed by 40 hex IN THE LINE. `RB_TEXT` carries
  # the `note=` trailer, a note is free-form, and a note naming a sha (`also fails
  # at @ <sha>`, a plausible thing for a lane to write) therefore WON the match:
  # measured, the sed returned the note's sha instead of the minted head, so the
  # recovered record bound to a head the negative was never minted at.
  #
  # Both expansions below are SHORTEST-prefix (`#`), so each takes the EARLIEST
  # occurrence, and the head's ` @ ` is the first one after `verdict=` by the
  # marker's own grammar (RB_RE has already proved that grammar above):
  #   verdict=<v> @ <40hex> [diff=<64hex>] (<repo>) [findings=<n> [note=<rest>]]
  # `verdict=` cannot appear before the verdict (the fixed prefix is
  # `review recorded: reviews/<pr>.json `), the verdict token contains no ` @ `,
  # and the note/diff/repo all come AFTER the head — so nothing a note contains can
  # move the read, whether or not this version is the one that wrote the note.
  RB_AFTER_VERDICT="${RB_TEXT#*verdict=}"
  RB_AFTER_HEAD="${RB_AFTER_VERDICT#* @ }"
  RB_HEAD="${RB_AFTER_HEAD:0:40}"
  if ! [[ "$RB_HEAD" =~ ^[0-9a-f]{40}$ ]]; then
    echo "record-review.sh --recover-body: the marker for $REPO#$PR matched the marker grammar but its head could not be read structurally (got '${RB_HEAD:0:40}') — a record bound to a half-read sha is worse than no record, because the gate would key on a head the review never happened at. Nothing was written." >&2
    exit 3
  fi
  # ⛔ A `clean-low` MARKER CANNOT BE RECOVERED HONESTLY (review, #2872 P0).
  # That tier certifies the MERGE BASE the diff was taken from, and a normal
  # clean-low record always carries `merge_base_sha`. The signed marker does NOT
  # carry it, so a recovered clean-low would (a) claim a shape a normal record of
  # that tier never has, and (b) diverge the two surfaces that read it: the
  # harness rail skips its B10 base-repointing guard when the field is absent
  # (atomic-land.sh — the #1348 hazard: `gh pr edit --base` after the review
  # moves what merges while the head sha still matches), while the
  # review-enforcer gate hard-blocks the same record with `base_unverifiable`.
  # One record, two verdicts. Refuse, and name the remedy that IS available: mint
  # it again at the current head — a FRESH mint, NOT a carry (this script's
  # `carry` is a specific mint state, with `carried_from`/`carried_at` and an
  # inherited reviewed_at, and there is no prior record here to carry from).
  if [ "$RB_VERDICT" = "clean-low" ]; then
    echo "record-review.sh --recover-body: $REPO#$PR's marker is a \`clean-low\` attestation, which certifies the MERGE BASE of the diff — and the signed marker does not carry \`merge_base_sha\`. A recovered clean-low would be a record of a shape that tier never has: the rail would skip its base-repointing guard while the gate refuses the same record as \`base_unverifiable\`. Nothing written. Mint it again at the current head instead — a FRESH mint (not a carry: nothing is stale), and the clean-low content-shape guard still has to pass: record-review.sh $PR <current head> clean-low $REPO" >&2
    exit 3
  fi
  RB_DIFF=""
  case "$RB_TEXT" in
    *" diff="*) RB_DIFF="${RB_TEXT#* diff=}"; RB_DIFF="${RB_DIFF%% *}" ;;
  esac
  # reviewed_at: the MINT time is UNKNOWN to this box, and this verb must not
  # pretend otherwise. It is NOT `now` (that is tortoise#7391: a carry/restore
  # time masquerading as the review time), and it is not the head commit's date
  # either — that is a LOWER BOUND (and a committer can set GIT_COMMITTER_DATE).
  # The bound is still the most honest thing available, and it matters beyond
  # labelling: `registry-sync.sh` orders records on `reviewed_at` alone, so a
  # recovered record loses to any peer record with a later stamp — which is the
  # safe direction (the peer keeps its verdict), and is why this field must never
  # be inflated. `mint=recovered-body` + `recovered_at` say what it really is.
  # `|| RB_AT_RC=$?` is load-bearing: this script runs under `set -e`, so a bare
  # `VAR="$(cmd)"` whose command fails ABORTS the whole verb with the command's
  # status (measured: exit 1 where this mode documents 3), skipping every branch
  # below. The capture is what makes the permanent-vs-transient split reachable.
  RB_AT_RC=0
  RB_AT_RAW="$(command gh api "repos/$REPO/commits/$RB_HEAD" --jq .commit.committer.date 2>&1)" || RB_AT_RC=$?
  RB_AT="$RB_AT_RAW"
  case "$RB_AT" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*) ;;
    *)
      if [ "$RB_AT_RC" -ne 0 ] && rb_is_permanent_gh_error "$RB_AT_RAW"; then
        echo "record-review.sh --recover-body: the marker names head ${RB_HEAD:0:12}… but this repo has no such commit and retrying will NOT help — gh said: $(printf '%s' "$RB_AT_RAW" | command head -1 | cut -c1-160). A force-pushed marker head, or a commit that only exists on a fork, reads this way: re-record at the current head instead. Nothing was written." >&2
      else
        echo "record-review.sh --recover-body: could not read the committer date of ${RB_HEAD:0:12}… (got '${RB_AT:0:40}'), so even a LOWER BOUND for reviewed_at cannot be stated — and this verb will not stamp a time the review did not happen (tortoise#7391). RETRY; nothing was written." >&2
      fi
      exit 3 ;;
  esac
  mkdir -p "$HOME/.pi/agent/reviews"
  RB_TMP="$RB_FILE.tmp.$$"
  # ⛔ RE-CHECK IMMEDIATELY BEFORE THE WRITE (review, #2872 P1), AND RE-CHECK THE
  # WHOLE RULE, NOT HALF OF IT (round 2, P2). `rb_existing_record` answers only
  # for THIS repo, so a FOREIGN identical-slug record landing in the same window
  # would still be destroyed by the `mv` below. Both arms are tested here, at the
  # write, where no further network read follows.
  if [ -f "$RB_FILE" ]; then
    if ! rb_names_this_repo "$RB_FILE"; then
      echo "record-review.sh --recover-body: a FOREIGN-repo record for $REPO#$PR appeared WHILE this recovery was reading the PR — refusing to destroy another repo's verdict. Nothing was written." >&2
      exit 5
    fi
    echo "record-review.sh --recover-body: a record for $REPO#$PR appeared WHILE this recovery was reading the PR (a concurrent recorder?) — refusing to replace it with an older verdict. Nothing was written; re-run --check-carry to see which verdict now stands." >&2
    exit 5
  fi
  if rb_existing_record; then
    echo "record-review.sh --recover-body: a record for $REPO#$PR appeared WHILE this recovery was reading the PR (a concurrent recorder?) — refusing to replace it with an older verdict. Nothing was written; re-run --check-carry to see which verdict now stands." >&2
    exit 5
  fi
  RB_DIFF_FIELD=""
  [ -n "$RB_DIFF" ] && RB_DIFF_FIELD="\"diff_sha256\":\"$RB_DIFF\","
  # #3400 — a recovered NEGATIVE record keeps its finding count, so the gate's
  # diagnosis survives the box change that recovery exists for. Absent for every
  # clean tier (empty string), so their record shape is unchanged.
  RB_FINDINGS_FIELD=""
  if [ "$RB_VERDICT" = "not-clean" ]; then
    # `$RB_FINDINGS` is CANONICAL by here (P3-5: the parse path strips leading
    # zeros and refuses a zero), so this write cannot emit `007`/`00` verbatim.
    RB_FINDINGS_FIELD="\"findings\":$RB_FINDINGS,"
    if [ -n "$RB_NOTE" ]; then RB_FINDINGS_FIELD="${RB_FINDINGS_FIELD}\"findings_note\":\"$RB_NOTE\","; fi
  fi
  printf '{"pr":%d,"head_sha":"%s",%s%s"mint":"recovered-body","recovered_at":"%s","marker_sig":"%s","verdict":"%s","repo":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$RB_HEAD" "$RB_DIFF_FIELD" "$RB_FINDINGS_FIELD" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RB_SIG" "$RB_VERDICT" "$REPO" "$RB_AT" > "$RB_TMP"
  # ⛔ THE LAST STEP IS ATOMIC, NOT CHECK-THEN-RENAME (round 3, P2). The re-check
  # above narrows the window to a couple of subprocesses; only a NO-CLOBBER CREATE
  # closes it. `ln` in the SAME directory is the portable compare-and-swap: it
  # fails with EEXIST rather than replacing, so a record that appears in the last
  # instant is reported instead of silently destroyed.
  if ! ln "$RB_TMP" "$RB_FILE" 2>/dev/null; then
    rm -f "$RB_TMP"
    if [ -f "$RB_FILE" ] && ! rb_names_this_repo "$RB_FILE"; then
      echo "record-review.sh --recover-body: a FOREIGN-repo record for $REPO#$PR took the path in the last instant — refusing to destroy another repo's verdict. Nothing was written." >&2
    else
      echo "record-review.sh --recover-body: a record for $REPO#$PR appeared in the LAST INSTANT (the atomic create refused: it already exists) — refusing to replace it with an older verdict. Nothing was written; re-run --check-carry to see which verdict now stands." >&2
    fi
    exit 5
  fi
  rm -f "$RB_TMP"
  # ⛔ THE DURABLE CHANNEL, ALSO HERE (#3168 fresh-review finding 1). `--recover-body`
  # exists BECAUSE the PR body is the only copy this verb can READ — until #1224, the
  # only one that travelled — so the one verb whose entire purpose is durability must
  # not hand the recovered evidence back into the same MUTABLE field it was read from,
  # leaving a later body edit able to erase the only admitted copy. `$RB_LINE` is the
  # HMAC-VERIFIED marker line the scan above required, so post_marker_comment()'s own
  # unsigned guard and line-anchored dedup apply here unchanged, exactly as at the
  # mint and failure arms. ⛔ ITS STDOUT GOES TO STDERR: this verb's stdout is a
  # MACHINE-READABLE tuple (`recovered<TAB><head><TAB><digest>`, pinned by 11.14a and
  # 11.14p), so an informational line on stdout would corrupt the contract every
  # caller parses. Best-effort: it cannot change this verb's result or exit.
  post_marker_comment "$REPO" "$PR" "$RB_LINE" >&2 || true
  printf 'recovered\t%s\t%s\n' "$RB_HEAD" "${RB_DIFF:--}"
  echo "record-review.sh --recover-body: restored ${REPO}#$PR from the SIGNED marker in the PR body → ${RB_FILE/#$HOME/~} (verdict=${RB_VERDICT}, head=${RB_HEAD:0:12}…, mint=recovered-body). ⛔ reviewed_at is a LOWER BOUND, not the mint time: the review happened at or after the head commit's committer date ($RB_AT) — this box did not observe the mint, and recovered_at says when the restoration happened. This restores a verdict, it does not certify one: ask the gate whether it still covers what would merge — record-review.sh --check-carry $PR $REPO" >&2
  exit 0
fi

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

# ── --delta: the MEASUREMENT half of a delta re-attestation (#10583) ─────────
# A conflict-free forward-merge of the base moves the HEAD and rewrites the
# RENDERED diff (hunk context and line numbers), so `diff_sha256` moves and the
# record reads stale — even though no AUTHORED line changed. The predicate that
# decides this already exists: `lane_dimension_carry` (clauses A-D) and
# `patch_dimension_carry` (#1377). ⛔ THIS FUNCTION DECIDES NOTHING. It prints the
# three facts a delta re-attestation makes its claim on, so the claim can be READ
# rather than inferred; the arms above remain the single decider.
#   authored-digest-equal     the #1377 PATCH projection (blob ids, hunk line
#                             numbers and hunk CONTEXT dropped) of the three-dot
#                             diff at BOTH heads — the reviewer's lines, unchanged
#   zero-conflict             a clean re-merge of (from, its base parent) reproduces
#                             the head's tree exactly ⇒ no resolution was authored
#   no-new-authored-commits   no non-merge commit between from and to that is not
#                             base lineage ⇒ a fix commit is authorship, a base
#                             merge commit is not
# A measurement is NOT a verdict: a `no` here does not itself refuse (the arms
# refuse) and a `yes` does not itself carry (the arms carry).
# ── --delta: WHICH PROOF FIELDS AN ARM MAY CLAIM (#3247) ─────────────────────
# EACH FIELD NAMES THE PREDICATE THAT MEASURED IT -- never the arm that happened
# to fire. ONE definition, so the writer and a pin cannot drift apart:
#   `authored_unchanged` is a claim about the AUTHORED DIGEST, measured only by
#     `patch` (#1377 projection really equal) and `diff` (rendered bytes really
#     identical).
#   `conflicts` is a claim about a RE-MERGE, measured ONLY by `lane` (clause D:
#     merge-tree rc=0 AND the merged tree equals the head's tree). `patch` never
#     re-merges, and a `diff` delta taken across a REBASED head has no second
#     parent -- its own triple prints `zero-conflict=UNMEASURED` -- so neither may
#     claim it. MEASURED as a bug: keying both fields on `patch|diff` wrote
#     "conflicts":0 beside a triple that said UNMEASURED.
delta_proof_fields() { # <arm> -> JSON fragment WITH its trailing comma, or empty
  case "$1" in
    patch|diff) printf '"authored_unchanged":true,' ;;
    lane)       printf '"conflicts":0,' ;;
  esac
}

# ── --delta: THE HEAD THE DECIDING ARM MEASURED (#3247 review, P1) ───────────
# The arms do NOT all start from the record's head. `diff` proves the prior
# signed marker's `diff=` equals the LIVE digest -- the head it measured is that
# marker's own (DIFF_ARM_SHA) -- and `patch` re-derives BOTH sides from
# PRIOR_PATCH_SHA. Only `lane` measures from the record's head (DELTA_FROM).
# Writing `delta.from=DELTA_FROM` beside `authored_unchanged:true` therefore made
# the signed record assert an authored-unchanged fact about a pair the run NEVER
# measured -- MEASURED on a stale record plus a peer-signed marker at a later
# head: the record said `from=<record head> … authored_unchanged:true` while the
# same run's triple printed `authored-digest-equal=no` and `commits=2`. That is
# the identical defect class as the `conflicts` one, on the `from` axis, so the
# record now names the head the proof covers. `carried_from` still records the
# RECORD's head, so both facts survive and a reader can tell them apart.
delta_measured_from() { # <arm> <record-head> <diff-arm-sha> <patch-arm-sha>
  case "$1" in
    diff)  [ -n "$3" ] && { printf '%s' "$3"; return 0; } ;;
    patch) [ -n "$4" ] && { printf '%s' "$4"; return 0; } ;;
  esac
  printf '%s' "$2"
}

delta_measure() { # <from-sha> <to-sha> ; prints facts to stdout. Never decides.
  local from="$1" to="$2" b="" p2="" mt="" mt_raw="" m_rc=0 ct="" extra="" pd1="" pd2="" n="" dtmp="" n3="" _seen=0 _ln=""
  local -x GIT_NO_REPLACE_OBJECTS=1 GIT_GRAFT_FILE=/dev/null
  b="$(command gh api "repos/$REPO/pulls/$PR" --jq .base.sha 2>/dev/null || true)"
  case "$b" in *[!0-9a-f]* | "") b="" ;; esac
  if [ "${#b}" -ne 40 ]; then b=""; fi
  # (1) authored digest: the #1377 patch projection of the LOCAL three-dot render.
  patch_projection() { # <sha> -> 64-hex on stdout, rc 1 = uncomputable
    [ -n "$b" ] && [ -n "$dtmp" ] || return 1
    command git -c diff.relative=false diff --no-color --no-ext-diff "$b...$1" 2>/dev/null > "$dtmp" || return 1
    command grep -qE '^diff --git ' "$dtmp" 2>/dev/null || return 1
    command python3 "$DIFF_NORMALIZER" --patch-only < "$dtmp" > "$dtmp.p" 2>/dev/null || return 1
    [ -s "$dtmp.p" ] || return 1
    command openssl dgst -sha256 < "$dtmp.p" | command awk '{print $NF}'
  }
  dtmp="$(command mktemp 2>/dev/null || true)"
  if [ -n "$dtmp" ]; then
    pd1="$(patch_projection "$from" 2>/dev/null || true)"
    pd2="$(patch_projection "$to" 2>/dev/null || true)"
    command rm -f "$dtmp" "$dtmp.p"
  fi
  case "$pd1" in *[!0-9a-f]* | "") pd1="" ;; esac
  case "$pd2" in *[!0-9a-f]* | "") pd2="" ;; esac
  if [ -n "$pd1" ] && [ -n "$pd2" ]; then
    if [ "$pd1" = "$pd2" ]; then
      printf 'authored-digest-equal=yes from=%s to=%s\n' "${pd1:0:12}" "${pd2:0:12}"
    else
      printf 'authored-digest-equal=no from=%s to=%s\n' "${pd1:0:12}" "${pd2:0:12}"
    fi
  else
    printf 'authored-digest-equal=UNMEASURED(patch projection uncomputable at %s)\n' "$([ -n "$b" ] && echo 'a head' || echo 'no authoritative base')"
  fi
  # (2) zero-conflict: clause (D) stated as a fact.
  p2="$(command git rev-parse "$to^2" 2>/dev/null || true)"
  # ⛔ `git rev-parse` ECHOES ITS LITERAL ARGUMENT to stdout on failure (measured:
  # `rev-parse '<sha>^2'` on a non-merge prints `<sha>^2` and exits 128), so an
  # ungated p2 makes the "no second parent" branch UNREACHABLE and reports a
  # merge-tree failure instead of the honest reason. Same 40-hex rule the
  # authoritative-base read above applies.
  case "$p2" in *[!0-9a-f]*) p2="" ;; esac
  [ "${#p2}" -eq 40 ] || p2=""
  ct="$(command git rev-parse "$to^{tree}" 2>/dev/null || true)"
  case "$ct" in *[!0-9a-f]*) ct="" ;; esac
  [ "${#ct}" -eq 40 ] || ct=""
  if [ -n "$p2" ] && [ -n "$ct" ]; then
    # rc IS CHECKED HERE TOO: `merge-tree --write-tree` PRINTS A TREE OID ON LINE 1 EVEN WHEN IT
    # CONFLICTS (exit 1) — the reason clause (D) requires rc=0 — so comparing the oid alone would
    # report a CONFLICTED re-merge as a clean fact. A conflict here is what proof (c) must show, so
    # it reports `no` with the conflict named rather than a silent oid comparison.
    # rc IS CARRIED HERE TOO. `git merge-tree --write-tree` PRINTS A TREE OID ON LINE 1 EVEN WHEN IT
    # CONFLICTS (exit 1) — the reason clause (D) requires rc=0 — and an earlier cut piped it through
    # `head -1 || true`, discarding the status (and `${PIPESTATUS[0]}` cannot recover it inside a
    # command substitution). Capture the OUTPUT, then the STATUS. A conflicted re-merge is a
    # legitimate `no` (that is proof (c)); only a merge-tree that produced NO tree is UNMEASURED.
    # ⛔ AND `VAR="$(…)"` IS ONE FAILING COMMAND UNDER `set -e`: a command substitution inside an
    # assignment propagates its status into `$?`, so the two statements this line used to be
    # (`mt_raw="$(…)"; m_rc=$?`) let the SHELL abort before `m_rc` was ever read — the second
    # statement could not run, and `rc=%s` plus this whole `zero-conflict=no … (a RESOLUTION is
    # authored code)` branch were UNREACHABLE exactly where they were written. MEASURED on a record
    # naming a NONEXISTENT reviewed head (`git merge-tree` exits 1 with `merge-tree: <sha> - not
    # something we can merge` and prints no tree oid at all): exit 1 with the
    # triple truncated after `authored-digest-equal=UNMEASURED(…)`, so `zero-conflict=` and
    # `no-new-authored-commits=` never printed and an intended refusal came out as a crash. This is the
    # same `|| rc=$?` idiom clause (D) of `lane_dimension_carry` and the rev-list walk below use. It is
    # DIAGNOSTIC REACHABILITY ONLY: the arms above remain the decider, and this line's status is
    # evidence they already acted on — no gate is loosened here.
    m_rc=0
    mt_raw="$(command git merge-tree --write-tree "$from" "$p2" 2>/dev/null)" || m_rc=$?
    # ⛔ NO PIPE HERE, for the reason this file MEASURED at its clean-low reader: under
    # `set -o pipefail` a `head` that exits after its one line sends SIGPIPE to the writer, the
    # substitution fails, and `set -e` aborts the script with NO output at all (measured there: 9 of
    # 40 identical runs produced empty stdout). Here that would delete the very diagnostic the guard
    # above exists to make reachable. `${x%%$'\n'*}` is the BASH-native first line the file already
    # uses for this. The other pre-existing `printf … | head` sites in this file are NOT touched here.
    mt="${mt_raw%%$'\n'*}"
    if [ -z "$mt" ]; then
      printf 'zero-conflict=UNMEASURED(merge-tree produced no tree, rc=%s)\n' "$m_rc"
    elif [ "$mt" = "$ct" ] && [ "$m_rc" -eq 0 ]; then
      printf 'zero-conflict=yes merged-tree=%s head-tree=%s\n' "${mt:0:12}" "${ct:0:12}"
    else
      printf 'zero-conflict=no merged-tree=%s head-tree=%s rc=%s (a RESOLUTION is authored code)\n' "${mt:0:12}" "${ct:0:12}" "$m_rc"
    fi
  else
    printf 'zero-conflict=UNMEASURED(no second parent on %s — not a forward merge)\n' "${to:0:12}"
  fi
  # (3) no new authored commits: clause (C2) stated as a fact.
  if [ -n "$b" ]; then
    # ⛔ THE WALK'S STATUS IS CHECKED, exactly as clause (C2) checks its own: a failed walk
    # prints NOTHING, and "nothing" here would read as "no authored commits" — the fail-open
    # direction, and this is the path where the reviewed head may genuinely be absent (a
    # cross-box record, a pruned or force-pushed head). MEASURED by a reviewer against a record
    # naming a nonexistent head: before this guard the triple printed `yes commits=0` about a head
    # that does not exist, next to two honest UNMEASURED lines.
    n_rc=0
    extra="$(command git rev-list --no-merges "$from..$to" --not "$b" 2>/dev/null)" || n_rc=$?
    if [ "$n_rc" -ne 0 ]; then
      printf 'no-new-authored-commits=UNMEASURED(rev-list failed rc=%s)\n' "$n_rc"
      n=""
    else
    n="$(printf '%s\n' "$extra" | command grep -c . || true)"
    fi
    if [ -z "$n" ]; then
      : # already reported UNMEASURED above
    elif [ "$n" -eq 0 ]; then
      printf 'no-new-authored-commits=yes commits=0\n'
    else
      # ⛔ NO PIPE HERE EITHER (#3247 review, P3). This is the `no-new-authored-commits` listing and
      # it was the ONE remaining `printf … | head -3 | tr | sed` in the file, ~30 lines below the `mt`
      # line above and ~90 below the reader whose 9-in-40 empty-stdout measurement justifies de-piping
      # that shape. It did NOT fault — the pipeline is an ARGUMENT to the outer `printf`, so the 141
      # was never a command's own status — but "this instance happens not to fault" is not a reason to
      # keep one convention for the diagnostic the arms above exist to make reachable and another
      # everywhere else: the next edit that hoists it into a statement would ARM the bug. Built in
      # BASH, like `${mt_raw%%$'\n'*}` above: no writer process exists, so nothing can be signalled.
      # (`mapfile`/`readarray` are NOT available — this file must run on bash 3.2.)
      while IFS= read -r _ln; do
        if [ "$_seen" -lt 3 ]; then
          n3="${n3:+$n3,}$_ln"; _seen=$((_seen+1))
        else
          break
        fi
      done <<<"$extra"
      printf 'no-new-authored-commits=no commits=%s %s\n' "${n:-0}" "$n3"
    fi
  else
    printf 'no-new-authored-commits=UNMEASURED(no authoritative base read)\n'
  fi
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
target_head_red() { # <head> -> 0 = measurably red, 1 = not shown red, 2 = the surface was NOT READ
  local raw
  # ⛔ THREE OUTCOMES, NOT TWO (#2342). This used to be `... 2>/dev/null || true` followed by
  # `[ -n "$raw" ] || return 1`, which made a REFUSED read indistinguishable from an EMPTY surface —
  # so a spent budget (or, after #2342, a floor refusal) let the clause-E veto be skipped and a SIGNED
  # `clean` re-bound onto a head whose own checks were never seen. That is the fail-open the veto
  # exists to close, reachable from a read that never happened. A failed READ is its own answer.
  if ! raw="$(command gh api "repos/$REPO/commits/$1/check-runs?per_page=100&filter=all" \
           --paginate \
           --jq '.check_runs[] | "\(.app.slug // "?")|\(.name)|\(.id)|\(.status)|\(.conclusion // "null")"' 2>/dev/null)"; then
    return 2                       # UNREADABLE — not red, and NOT “not red” either
  fi
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
  # #1377 — initialised OUTSIDE the diff-read arm below: `set -u` makes a
  # reference to an unset name a fatal error, and the patch arm's PREDICATE is
  # named on the same line as the byte-identity arm, which runs even when the
  # live diff could not be read (DIFF_HASH empty). Leaving these to be set only
  # inside that arm aborted the whole record with rc 1 instead of reaching the
  # guard's refusal.
  PRIOR_PATCH_SHA=""
  PRIOR_PATCH_NORM=""
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
  elif [ -n "$EXPECT_HEAD" ] && [ "$CURRENT_HEAD" != "$EXPECT_HEAD" ]; then
    # tortoise#9492 — the caller PINNED the head. Refuse rather than let the
    # carry arms decide: the carry is right about the PR head's diff and
    # silent about the caller's intent, so carrying here would answer a
    # question nobody asked ("attest <CURRENT_HEAD>") while the record still
    # looks like it names the tree the reviewer read.
    EXPECT_HEAD_REF="$(command gh api "repos/$REPO/pulls/$PR" --jq .head.ref 2>/dev/null || true)"
    EXPECT_BRANCH_SHA=""
    if [ -n "$EXPECT_HEAD_REF" ] && [ "$EXPECT_HEAD_REF" != "null" ]; then
      EXPECT_BRANCH_SHA="$(command gh api "repos/$REPO/git/matching-refs/heads/$EXPECT_HEAD_REF" --jq '.[0].object.sha' 2>/dev/null || true)"
    fi
    echo "⛔ --expect-head: the PR head is $CURRENT_HEAD, NOT the $EXPECT_HEAD you named — refusing to record (no record written, no marker posted)." >&2
    if [ "$EXPECT_BRANCH_SHA" = "$EXPECT_HEAD" ]; then
      echo "   refs/heads/${EXPECT_HEAD_REF:-<unknown>} IS at ${EXPECT_HEAD:0:12}… — GitHub's PR ref is behind its own branch (a wedged PR head). Re-binding the record to ${CURRENT_HEAD:0:12}… would attest a tree you did not name, so nothing is written." >&2
      echo "   Remedy: open a fresh PR from the branch (a wedged PR ref cannot be reopened once closed — tortoise#9492 measured both), then record at the new head." >&2
    else
      echo "   Neither the PR ref ($CURRENT_HEAD) nor refs/heads/${EXPECT_HEAD_REF:-<unknown>} (${EXPECT_BRANCH_SHA:-unreadable}) is at ${EXPECT_HEAD} — re-check the sha you reviewed." >&2
    fi
    exit 3
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
          DIFF_ARM_SIG="$PRIOR_SIG"
          DIFF_ARM_SHA="$(printf '%s' "$PRIOR_TEXT" | command sed -n 's/.* @ \([0-9a-f]\{40\}\) diff=.*/\1/p')"
        else
          echo "⚠️ #784: found prior evidence in the PR body with the right shape but a BAD SIGNATURE — ignoring it (the PR body is not a trust boundary)" >&2
        fi
      fi
      # ── #1377 — THE PATCH ARM'S EVIDENCE ────────────────────────────────
      # The arm above needs the prior marker's `diff=` to equal the LIVE
      # normalized digest. A REBASE onto a moved base breaks that even when
      # every reviewed line is identical: `main` landing work in the same file
      # rewrites the hunk CONTEXT, and the binding keeps context (#1362 D1).
      # This finds a VERIFIED marker at whatever head it names and hands the
      # decision to `patch_dimension_carry`, which re-derives BOTH sides.
      #
      # ⛔ NOTHING IS TRUSTED FROM THE BODY HERE. The marker must HMAC-verify
      # with the gate key (#784 — the same rule the arm above applies), and its
      # `diff=` is then the ANCHOR the reconstructed reviewed diff must
      # reproduce. So the bytes this arm compares are the bytes that marker was
      # minted over, never bytes the body merely asserts.
      if [ -n "$GATE_KEY" ]; then
        # NEWEST FIRST: a body can carry several markers (each re-record appends
        # one), and only the most recent describes the artifact up for merge.
        # `awk` reversal, not `tac` — macOS does not ship `tac`.
        PRIOR_SCAN="$(printf '%s\n' "$PRIOR_BODY" \
          | command grep -E "^review recorded: reviews/${PR}\.json verdict=${VERDICT} @ [0-9a-f]{40} diff=[0-9a-f]{64} \\(${REPO}\\) sig=[0-9a-f]{64}$" \
          | command awk '{a[NR]=$0} END{for(i=NR;i>0;i--) print a[i]}' || true)"
        while IFS= read -r PP_LINE; do
          [ -n "$PP_LINE" ] || continue
          PP_TEXT="${PP_LINE% sig=*}"
          PP_SIG="${PP_LINE##* sig=}"
          PP_EXPECT="$(printf '%s' "$PP_TEXT" | command openssl dgst -sha256 -hmac "$GATE_KEY" 2>/dev/null | command awk '{print $NF}' || true)"
          # A forged or corrupted line is SKIPPED, not fatal: the body may carry
          # older markers this PR's own re-records produced.
          [ -n "$PP_EXPECT" ] && [ "$PP_SIG" = "$PP_EXPECT" ] || continue
          PP_SHA="$(printf '%s' "$PP_TEXT" | command sed -n 's/.* @ \([0-9a-f]\{40\}\) diff=.*/\1/p')"
          PP_NORM="$(printf '%s' "$PP_TEXT" | command sed -n 's/.* diff=\([0-9a-f]\{64\}\).*/\1/p')"
          [ "${#PP_SHA}" -eq 40 ] && [ "${#PP_NORM}" -eq 64 ] || continue
          PRIOR_PATCH_SHA="$PP_SHA"
          PRIOR_PATCH_NORM="$PP_NORM"
          # THE PATCH ARM'S OWN PAIR, from THIS marker. It is kept in separate
          # names on purpose: this scan keeps the NEWEST verified marker while the
          # diff arm keeps the OLDEST (`grep -m1`), so a shared variable would let
          # one arm's `@ <sha>` be reported with the other's `sig=` — an HMAC that
          # verifies against nothing (fresh-review cycles 2-3).
          PATCH_ARM_SIG="$PP_SIG"
          PATCH_ARM_SHA="$PP_SHA"
          break
        done <<< "$PRIOR_SCAN"
      fi
    fi
    # Which carry arm applies? Decided FIRST so that clause (E) can veto a carry that
    # neither arm's own conditions can see: both arms prove the LANE's artifact is
    # unchanged, and neither says anything about the health of the head it binds to.
    CARRY_ARM=""
    if [ -n "$PRIOR_DIFF" ]; then
      CARRY_ARM="diff"
    elif [ "$FORCE_STALE" -ne 1 ] && patch_dimension_carry "$PRIOR_PATCH_SHA" "$PRIOR_PATCH_NORM" "$CURRENT_HEAD"; then
      CARRY_ARM="patch"
    elif [ "$FORCE_STALE" -ne 1 ] && lane_dimension_carry "$SHA" "$CURRENT_HEAD"; then
      CARRY_ARM="lane"
    fi
    if [ -n "$CARRY_ARM" ]; then
      # (E) (#1575) — the veto. Refuse BEFORE printing either arm's success line and
      # before re-binding SHA, so a red target never produces a signed `clean`.
      # ⛔ `set -e` IS ACTIVE HERE: a bare failing call ABORTS the script before the assignment, so the
      # three-way verdict must be captured in a condition context. (Measured: without `||`, every
      # carry arm exited 1 and 28 assertions reddened.)
      E_RC=0
      target_head_red "$CURRENT_HEAD" || E_RC=$?
      if [ "$E_RC" -ne 1 ]; then
        if [ "$E_RC" -eq 0 ]; then
        echo "⛔ (#1575 clause E) refusing the carry onto ${CURRENT_HEAD:0:12}… — the TARGET HEAD IS MEASURABLY RED." >&2
        echo "   A base-only move is still a change to the tree the verdict describes, so re-binding '$VERDICT' to it would put a SIGNED 'clean' on a head whose own checks are failing — an attestation that records a red tree as reviewed-green, and one the merge gate cannot see once the record outlives the run (#4823, #5395, #5292)." >&2
        echo "   The LANE's artifact IS unchanged — that is what the carry proved. Only the head's health is unknown or bad. Re-review at ${CURRENT_HEAD:0:12}…, or re-run the failing checks and re-record." >&2
        exit 3
        else
        echo "⛔ (#1575 clause E) refusing the carry onto ${CURRENT_HEAD:0:12}… — the TARGET HEAD'S CHECK SURFACE COULD NOT BE READ (UNREADABLE), so “not red” was never established." >&2
        echo "   A carry re-binds a SIGNED verdict to a new head, so it needs the head's health READ and not merely un-refuted: a REFUSED read (a spent budget, a floor refusal, an auth error) and an EMPTY surface are the same bytes on stdout, and only the exit status tells them apart. Re-read the head's checks once the budget window resets, or re-review at ${CURRENT_HEAD:0:12}… and re-record." >&2
        exit 3
        fi
      fi
      if [ "$DELTA" -eq 1 ]; then
        # ⛔ MEASURE AND REPORT THE PAIR THE ARM PROVED (#3247 review, P1). `delta_measured_from`
        # names the head the decider actually measured (see its definition), so the triple below is
        # evidence for the SAME pair the record will claim -- and the record write at the bottom of
        # this file uses the same function, so the diagnostic and the signed artifact cannot diverge.
        DELTA_MEASURED_FROM="$(delta_measured_from "$CARRY_ARM" "$DELTA_FROM" "$DIFF_ARM_SHA" "$PATCH_ARM_SHA")"
        echo "DELTA-TRIPLE($REPO#$PR) from=${DELTA_MEASURED_FROM:0:12}… to=${CURRENT_HEAD:0:12}… (arm=$CARRY_ARM)" >&2
        delta_measure "$DELTA_MEASURED_FROM" "$CURRENT_HEAD" >&2
        echo "DELTA-ARM=$CARRY_ARM (the arm above is the decider; the triple is the evidence it decided on)" >&2
      fi
      if [ "$CARRY_ARM" = "diff" ]; then
        echo "#2982 carry-forward: head moved ${SHA:0:12}… → ${CURRENT_HEAD:0:12}…, but the reviewed diff is unchanged (diff=${DIFF_HASH}) and already carries signed evidence — recording against the CURRENT head" >&2
      elif [ "$CARRY_ARM" = "patch" ]; then
        # #1377 — the head moved AND the rendered diff moved, but every reviewed
        # line is byte-identical: this is a rebase or a base move, not an edit.
        # The review is a review OF THE DIFF, so the verdict stands and only the
        # MECHANICAL re-record is owed. The binding is upgraded to the CURRENT
        # head's own digest by the marker minted below — never inherited.
        echo "#1377 patch carry: head moved ${SHA:0:12}… → ${CURRENT_HEAD:0:12}…, the rendered diff CHANGED (diff=${DIFF_HASH}) but the REVIEWED PATCH is byte-identical at both heads (verified against the prior signed marker's own diff=${PRIOR_PATCH_NORM:0:12}…; the reviewed side was ${PRIOR_PATCH_SHA:0:12}…) — a rebase/base-move, not an edit. Recording against the CURRENT head; NO new review cycle is owed" >&2
      else
        # The rendered patch moved (a base merge), but the LANE's artifact is
        # provably unchanged: the head only moved forward, no lane commit is in
        # between, and a clean re-merge of (reviewed, its base parent) reproduces
        # the head's tree exactly. Re-record against the CURRENT head, exactly as
        # the arm above does — the binding is to the head that will merge.
        echo "#6072/#6213/#4823 lane-dimension carry: head moved ${SHA:0:12}… → ${CURRENT_HEAD:0:12}…, the rendered diff changed but the LANE's commits are provably identical (forward move; no non-base NON-MERGE commit in between — an intervening merge is permitted, which is why the tree check below is load-bearing; the head's tree is exactly a clean merge of reviewed and its base parent) — recording against the CURRENT head" >&2
      fi
      # ── RECORD WHAT THIS CARRY CARRIED (#10177) ──────────────────────
      # `diff_sha256` alone cannot tell a reader which artifact a verdict covers,
      # because a carry re-derives it from the LIVE head — so it always equals what
      # would merge. These two digests are the missing halves: the artifact AS
      # REVIEWED, and the delta this head added beyond it. They are what makes a
      # carry auditable after the fact (and what a reviewer of this machinery can
      # check against the review it claims to re-bind).
      case "$CARRY_ARM" in
        diff)  CARRY_REVIEWED_DIFF="$DIFF_HASH"; CARRY_REVIEWED_SOURCE="marker" ;;
        patch) CARRY_REVIEWED_DIFF="$PRIOR_PATCH_NORM"; CARRY_REVIEWED_SOURCE="marker" ;;
        lane)
          # The LANE arm needs no signed marker, so the reviewed artifact's
          # identity is re-derived from the COMMITS (both present locally — the
          # arm's own clause (A)) rather than inherited from anything trustworthy.
          CARRY_BASE_FOR_REVIEWED="$(command gh api "repos/$REPO/pulls/$PR" --jq .base.sha 2>/dev/null || true)"
          if CARRY_REVIEWED_DIFF="$(carry_local_artifact_digest "$CARRY_BASE_FOR_REVIEWED" "$ORIG_SHA")"; then
            CARRY_REVIEWED_SOURCE="local"
          else
            CARRY_REVIEWED_DIFF=""; CARRY_REVIEWED_SOURCE=""
          fi ;;
      esac
      CARRY_DELTA_DIFF="$(carry_delta_digest "$ORIG_SHA" "$CURRENT_HEAD" 2>/dev/null || true)"
      SHA="$CURRENT_HEAD"
    elif [ "$FORCE_STALE" -ne 1 ] && [ "$DELTA" -eq 1 ]; then
      echo "⛔ --delta REFUSED for $REPO#$PR: the authored change is NOT provably unchanged between ${DELTA_FROM:0:12}… and ${CURRENT_HEAD:0:12}…, so no delta can be re-attested. Nothing was written." >&2
      echo "DELTA-TRIPLE($REPO#$PR) from=${DELTA_FROM:0:12}… to=${CURRENT_HEAD:0:12}…" >&2
      delta_measure "$DELTA_FROM" "$CURRENT_HEAD" >&2
      echo "   Read the triple: 'no' on ANY line is a fresh review (a changed authored digest, a conflict resolution, or a new authored commit each means a reviewer has not seen this); 'UNMEASURED' is not a 'yes'. A full review is owed — dispatch it, then record with --evidence comment:<id>." >&2
      exit 3
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
# tortoise#9492 — FAIL CLOSED when the pin could not be CHECKED. The guard above
# only runs with a resolvable $REPO and a gh on PATH; without them the caller's
# --expect-head would be silently ignored and a record written — the pin would
# look enforced while enforcing nothing. A pin that cannot be verified is a
# refusal, not a pass (the #784 fail-open is about an UNPINNED record).
if [ -n "$EXPECT_HEAD" ] && [ "$PRINT_DIFF_HASH" -ne 1 ] && [ "$CHECK_CARRY" -ne 1 ]; then
  if ! [[ "${CURRENT_HEAD:-}" =~ ^[0-9a-f]{40}$ ]] || [ "${CURRENT_HEAD:-}" != "$EXPECT_HEAD" ]; then
    echo "⛔ --expect-head: could not verify the PR head against ${EXPECT_HEAD} — refusing to record (no record written, no marker posted)." >&2
    echo "   Resolved head: ${CURRENT_HEAD:-<unavailable: no \$REPO, or gh missing/failing>}. A pin exists only if it is checked; recording without checking it would make --expect-head decorative." >&2
    exit 3
  fi
fi

# ── #10583 — A `--delta` THAT MINTED NOTHING IS NOT A SUCCESS ───────────────
# `--delta` is the ONE mode whose contract is "re-attest the record's verdict onto
# the live head". Every delta refusal lives INSIDE the stale-sha chain
# (`elif [ "$CURRENT_HEAD" != "$SHA" ]`), so a path that never enters that chain
# runs NO delta predicate at all — and the record write below is UNCONDITIONAL.
# MEASURED (fresh-context review of 426ac51b, reproduced against the real script
# with a stub gh whose second `.head.sha` read fails):
#
#   record BEFORE: {... "mint":"fresh", "verdict":"clean-micro", "evidence":"comment:9000001" ...}
#   rc=0, and AFTER: {... "mint":"fresh", "verdict":"clean-micro" ...}   ← evidence GONE
#   stderr: "stale-sha guard: could not fetch the current head … continuing fail-open"
#           "review evidence posted to … as a durable comment"
#
# Three claims that run never made, on a SUCCESSFUL exit: `mint:"fresh"` (no
# reviewer ran — delta mode REFUSES --evidence, :1590), the prior record's
# `evidence` (the one pointer tortoise#7391/#10177 exist to preserve) is DELETED,
# and a signed marker is PATCHed. The tortoise#7391 gate below cannot catch it
# because that gate is keyed on `VERDICT = clean`, and `clean-micro`/`clean-low`
# are clean-FAMILY but not `clean` — so the two verdicts a delta most often
# carries are exactly the two it does not cover. The racing-read variant (the
# second read returns the record's own head) skips the same chain and lands the
# same way, which is the #784 "pair that never coexisted" shape: a stale
# `head_sha` beside the live diff, which `--check-carry` then answers `carry` for.
#
# So state the post-condition the mode implies: a delta that reached the record
# write WITHOUT a carry arm re-attested NOTHING, and a no-op that exits 0 while
# rewriting the record is the false PASS this whole file exists to refuse. It is
# a refusal at 3, matching the delta block's own unreadable-head answer (also 3,
# "RETRY"), because a transient gh failure must be retried, never recorded.
if [ "$DELTA" -eq 1 ] && [ -z "$CARRY_ARM" ]; then
  echo "⛔ --delta REFUSED for ${REPO:-<no-repo>}#${PR:-?}: no carry arm ran, so NOTHING was re-attested — refusing to write a record. (no record written, no marker posted)" >&2
  echo "   A --delta whose head or diff could not be MEASURED is not a changed artifact and not an approval: the live head read did not put this invocation through the carry chain, so no arm could prove the authored change unchanged. Writing here would mint a fresh record for a head nothing measured, and would drop the prior record's review artifact." >&2
  echo "   Remedy: RETRY (a contended gh gate or a rate-limit window is far cheaper than a re-review). If the retry keeps failing, review the current head and record it fresh with --evidence comment:<id>." >&2
  exit 3
fi

# ── tortoise#7391 — a FRESH `clean` record must name a review artifact ───────────
# This is the branch the defect lived on. CARRY_ARM is set ONLY when a verified
# carry re-bound the verdict to the live head, so an empty CARRY_ARM means this
# invocation is minting a NEW `clean` attestation at the head it names — the
# case that, before this guard, recorded unconditionally with no evidence
# question asked on any path. NOTE this runs OUTSIDE the REPO/gh block above,
# so an invocation that cannot reach GitHub at all (no repo, missing gh) is
# refused rather than silently un-asked: verification is the point.
if { [ "$VERDICT" = "clean" ] || [ "$VERDICT" = "not-clean" ]; } && [ -z "$CARRY_ARM" ]; then
  if [ -z "$EVIDENCE" ]; then
    if [ "$VERDICT" = "not-clean" ]; then
      echo "⛔ #3400: refusing to mint a 'not-clean' record for ${SHA:0:12}… with NO review evidence." >&2
      echo "   A NEGATIVE verdict is still a claim that a review happened — the one it says was NOT clean — so it is held to the same evidence standard as 'clean'. Without the artifact, the record would assert that some review, somewhere, found something: no reader could check it, and a lane could mint it to park a PR it never reviewed." >&2
      echo "   → Name the artifact the review produced: record-review.sh $PR $SHA not-clean ${REPO:-<owner/repo>} --findings <n> --evidence <comment:<id> | review:<id> | review-comment:<id> | <its URL>>" >&2
      exit 3
    fi
    echo "⛔ tortoise#7391: refusing to mint a 'clean' record for ${SHA:0:12}… with NO review evidence." >&2
    echo "   A 'clean' verdict is a full-review attestation, and this invocation is a FRESH one: it is not a carry (no prior signed marker was verified for this diff), so nothing here shows a review happened." >&2
    echo "   Naming the PR's CURRENT head is not evidence — that is precisely the invocation that recorded an unreviewed diff before this guard existed (tortoise#7391; tortoise#3549 merged on exactly such a record while every review comment on it said NOT CLEAN)." >&2
    echo "   → Run the review, then name its artifact: record-review.sh $PR $SHA clean ${REPO:-<owner/repo>} --evidence <comment:<id> | review:<id> | review-comment:<id> | <its URL>>" >&2
    echo "   → If a verdict is ALREADY recorded at an earlier head and only the base moved, land via the rail (scripts/atomic-land.sh): it carries the verified record and needs no --evidence." >&2
    exit 3
  fi
  if ! verify_review_evidence "$EVIDENCE" "$SHA" "$VERDICT" >/dev/null; then
    echo "⛔ tortoise#7391: refusing to mint a '${VERDICT}' record for ${SHA:0:12}… — the named review evidence could not be verified (reason above)." >&2
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
# positional scan with a BOUNDARY-ANCHORED CLOSING_KW scan, because GitHub
# auto-closes a mid-sentence ref — a body like "Closes #100" + "This also
# closes #42" closes complex #42 on merge and must never record clean-micro off
# micro #100 alone. Refusal is the fail-closed direction, so the union widens
# the bind without widening the fail-open arms. The boundary on the parity class
# is the OTHER direction: an unanchored class matches inside English words,
# turning `The prefix #42 is unrelated.` into a refusal GitHub itself would
# never make (#1012 r3) — and it must fire after emphasis `_` (#1336), which a
# plain `\b` did not, letting a mid-sentence `_closes #N_` (which GitHub DOES
# close) record clean-micro with this guard silent.
if [ "$VERDICT" = "clean-micro" ]; then
  if [ -z "$REPO" ] || ! command -v gh >/dev/null 2>&1; then
    echo "⚠️ clean-micro tier guard: repo undetectable or gh missing — tier attestation UNVERIFIED (record proceeds; a non-micro linked issue should never be recorded clean-micro)" >&2
  else
    # ── THE SURFACE CAP (arm a0) ──────────────────────────────────────
    # Until this arm existed the micro tier was selected from the LINKED
    # ISSUE'S LABEL alone and never looked at the diff, so a
    # `complexity:micro` issue could record clean-micro for a one-line edit to
    # `scripts/admin-merge.sh` and skip the code-review skill entirely — the
    # micro flow dispatches no reviewers (03-code-review.md Step 2), so the
    # rail change would reach main with no review at all. That is the tier
    # being selected by how small the diff LOOKS, which is exactly what a
    # blast-radius selector must refuse.
    #
    # Fail-CLOSED on POSITIVE evidence — a rail path in the diff, OR a payload the
    # classifier cannot certify (rc 3: an unparseable row, no merge base, no
    # rows) — and fail-OPEN only on a TRANSPORT failure (rc 1: gh absent, a
    # non-2xx, an unreadable body), which is this guard's existing posture for
    # arms (a)-(c). The split is load-bearing: reusing one code for both made the
    # cap a NO-OP for any diff carrying a single row of an exotic status, which
    # is the bypass this arm exists to close.
    MICRO_RC=0
    MICRO_ROWS="$(review_surface_rows "$REPO" "$PR" "$SHA")" || MICRO_RC=$?
    if [ "$MICRO_RC" -eq 2 ]; then
      echo "❌ clean-micro surface cap: $REPO#$PR at ${SHA:0:12}… has NO changed files, so there is no surface to certify. Refusing (exit 4, no record)." >&2
      exit 4
    fi
    if [ "$MICRO_RC" -eq 3 ]; then
      # The cause list names EVERY rc-3 arm, including the one this cap was
      # written for: the compare 404 of an unreachable fork head. A message that
      # omits it makes the next lane re-diagnose the same 404 from scratch — the
      # exact failure the sibling clean-low guard's wording exists to prevent.
      echo "❌ clean-micro surface cap: $REPO#$PR at ${SHA:0:12}… — the changed-path payload cannot be certified. Causes: the compare endpoint REFUSED this revision (HTTP 404/422 — an unreachable fork head or a rewritten sha), answered with no readable body, returned no merge base, returned no rows, or returned a malformed row. A diff whose surface cannot be read cannot be cleared for a tier that dispatches no reviewers. Refusing (exit 4, no record). A TRANSPORT failure (403 rate-limit / 5xx / network) does NOT take this arm — it warns and proceeds — so a retry after the window is worth one attempt before paying for a full review." >&2
      echo "   → Run the code-review skill on the current head, then record clean with --evidence <artifact>." >&2
      exit 4
    fi
    if [ "$MICRO_RC" -ne 0 ]; then
      echo "⚠️ clean-micro surface cap: could not read the changed paths of $REPO#$PR at ${SHA:0:12}… (gh/API failure?) — the surface cap is UNVERIFIED (record proceeds; a micro issue whose diff touches a merge/land rail must never be recorded clean-micro)" >&2
    else
      MICRO_PATHS="${MICRO_ROWS#*$'\n'}"
      IFS=$'\t' read -r _tag_m _mb_m MICRO_EXPECT <<< "${MICRO_ROWS%%$'\n'*}"
      # NEW path only — see the parity note at the --print-tier seam: GitHub counts
      # a rename as one changed file, so counting both ends would refuse every
      # rename as "truncated". Classification still reads both ends.
      MICRO_DISTINCT="$(LC_ALL=C awk -F '\t' 'NF>=2 && $2 != "" { print $2 }' <<< "$MICRO_PATHS" | LC_ALL=C sort -u | wc -l | tr -d ' ')"
      if [ -z "$MICRO_DISTINCT" ] || [ "$MICRO_DISTINCT" -eq 0 ]; then
        echo "❌ clean-micro surface cap: read no changed paths for $REPO#$PR at ${SHA:0:12}… — a diff with no readable surface cannot be certified micro. Refusing (exit 4, no record)." >&2
        exit 4
      fi
      if [ "$MICRO_DISTINCT" -ge 300 ] || [ "$MICRO_DISTINCT" != "$MICRO_EXPECT" ]; then
        echo "❌ clean-micro surface cap: $REPO#$PR at ${SHA:0:12}… changes $MICRO_DISTINCT path(s) but GitHub reports $MICRO_EXPECT — the changed-path list is truncated or inconsistent, so the surface cap cannot be evaluated. Refusing (exit 4, no record); a diff that large is never micro." >&2
        exit 4
      fi
      MICRO_CAP="$(printf '%s\n' "$MICRO_PATHS" | review_tier_cap || true)"
      if [ "$MICRO_CAP" = "full" ]; then
        echo "❌ clean-micro surface cap: $REPO#$PR touches an ALWAYS-FULL surface — clean-micro certifies the micro PROCESS (no code-review dispatch), and a merge/land rail, a CI workflow or an extension is where a defect becomes a FALSE PASS at the last gate before main. The tier is selected by what the change can BREAK, not by how small it looks. Refusing (exit 4, no record)." >&2
        echo "   Offending paths:" >&2
        while IFS=$'\t' read -r _st _p _old; do
          [ -z "$_p" ] && continue
          MICRO_HIT=0
          review_full_surface_path "$_p" || MICRO_HIT=$?
          if [ "$MICRO_HIT" -eq 0 ] || [ "$MICRO_HIT" -eq 2 ]; then echo "     $_p" >&2; fi
        done <<< "$MICRO_PATHS"
        echo "   → Run the code-review skill on the current head at FULL depth, then record:" >&2
        echo "   →   record-review.sh $PR $SHA clean $REPO --evidence <artifact>" >&2
        echo "   →   (<artifact> = the review comment the skill posted, e.g. comment:<id>.)" >&2
        exit 4
      fi
    fi
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
      # BOUNDARY-ANCHORED (CLOSING_KW_BOUNDARY; #1012 r3 + #1336): the boundary
      # before the class keeps ordinary prose ("prefix", "discloses",
      # "unresolved") and intra-word underscores (`foo_closes`) from being read
      # as a keyword and refused, which would be a FALSE refusal — GitHub
      # requires a word boundary the unanchored scan did not — while still
      # firing after an EMPHASIS `_` (`_closes #N_`), which GitHub DOES close.
      REFS="$({ closing_issue_refs "$BODY"; closing_issue_refs "$BODY" "${CLOSING_KW_BOUNDARY}${CLOSING_KW}"; } | awk -F'#' 'tolower($1) == tolower("'"$REPO"'") { seen[$0]++; if (seen[$0] == 1) print }')"
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
  # Same native split as review_surface_rows, and for the same measured reason
  # (#2472 review): `printf … | head -1 | cut` under `set -o pipefail` lets a
  # `head` exit after its one line, SIGPIPE the writer, fail the substitution and
  # — under `set -e` — abort this script with NO output at all. That is a
  # SILENTLY stranded `clean-low` record (9 of 40 identical runs, measured on the
  # tier seam), so the idiom the new comment condemns is removed here too rather
  # than left as the one surviving copy.
  CMP_FIRST="${CMP%%$'\n'*}"
  if [[ "$CMP" == *$'\n'* ]]; then CMP_REST="${CMP#*$'\n'}"; else CMP_REST=""; fi
  MB="$(printf '%s' "$CMP_FIRST" | cut -f2)"
  RAW="$CMP_REST"
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
# ── CARRY EVIDENCE (#10177): a carried verdict must NAME the review behind it ──
# A carry used to omit `evidence` entirely, so `"evidence":null` was the normal
# shape of a re-bound verdict — a field that a reader is entitled to read as "no
# verdict" and that instead meant "trust me". It is now always populated, from the
# strongest source available, in this order:
#   1. the evidence ref of the record being superseded (the artifact the verdict
#      was originally minted against — the real thing);
#   2. the VERIFIED signed marker that anchored the carry (its `sig=` is an HMAC
#      over the reviewed head and digest, so it names the reviewed revision);
#   3. for a NON-`clean` verdict only, a pointer at the carried arm and head —
#      those tiers are not full-review attestations, so a pointer is the honest
#      claim. A `clean` carry with NO source at all is REFUSED: that is the exact
#      combination tortoise#10677 produced, and no reader could have caught it.
if [ -n "$CARRY_ARM" ] && [ -z "$EVIDENCE_VERIFIED" ]; then
  CARRY_EVIDENCE=""
  if [ -f "$FILE" ]; then
    CARRY_EVIDENCE="$(sed -n 's/.*"evidence":"\([^"]*\)".*/\1/p' "$FILE" 2>/dev/null | command head -1 || true)"
  fi
  # ⛔ THE ARM SELECTS THE PAIR (fresh-review cycle 3): a marker may only be named
  # by the arm that CONSUMED it. The lane arm proves itself from the commits and
  # consumes no marker, so it reports none — it falls through to the predecessor's
  # evidence or, for a non-`clean` tier, the `carry:` pointer.
  if [ -z "$CARRY_EVIDENCE" ]; then
    case "$CARRY_ARM" in
      diff)  CARRIED_SIG="$DIFF_ARM_SIG";  CARRIED_SHA="$DIFF_ARM_SHA" ;;
      patch) CARRIED_SIG="$PATCH_ARM_SIG"; CARRIED_SHA="$PATCH_ARM_SHA" ;;
      *)     CARRIED_SIG="";               CARRIED_SHA="" ;;
    esac
    if [ -n "$CARRIED_SIG" ]; then
      CARRY_EVIDENCE="marker:${REPO}#${PR}@${CARRIED_SHA:-$ORIG_SHA}#sig=${CARRIED_SIG}"
    fi
  fi
  if [ -z "$CARRY_EVIDENCE" ]; then
    if [ "$VERDICT" = "clean" ]; then
      echo "⛔ carry-provenance: refusing to CARRY a 'clean' verdict from ${ORIG_SHA:0:12}… onto ${CURRENT_HEAD:0:12}… — the carry proved the ARTIFACT is unchanged, but nothing here names the REVIEW ARTIFACT that verdict was minted against (the superseded record carries no evidence, and no verified signed marker anchors it). A carried 'clean' with no evidence is the shape tortoise#10677 produced: a verdict re-bound to a tree with nothing in it a reader could check, so it is refused rather than minted (no record written, no marker posted)." >&2
      echo "   Remedy: review the current head and record it fresh with --evidence <comment:<id>|review:<id>|…>; a carry cannot manufacture the artifact it is supposed to inherit." >&2
      exit 3
    fi
    CARRY_EVIDENCE="carry:${CARRY_ARM}:${ORIG_SHA:0:12}"
  fi
  echo "carry provenance: evidence=${CARRY_EVIDENCE} (inherited — a carry re-binds a verdict, it does not mint one), arm=${CARRY_ARM}, reviewed_diff=${CARRY_REVIEWED_DIFF:-unavailable} (${CARRY_REVIEWED_SOURCE:-unavailable}), delta=${CARRY_DELTA_DIFF:-unavailable}" >&2
fi
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
  # #10583 — a DELTA is its own mint state. It is NOT `fresh` (no reviewer ran at
  # this head) and it must not be reported as a plain `carried` either: a carrier is
  # a rebase/base-move whose provenance is unrecorded, while this one carries a
  # CLAIM about the authored change that a reader must be able to check. So the
  # record names the pair, and the delta it attests.
  # ⛔ NAME WHAT THE ARM PROVED, not what would read well. A reviewer measured that the
  # `authored_unchanged:true` this field used to hardcode is contradicted by the SAME run's own
  # triple on the commonest path: `arm:"lane"` proves the LANE dimension (forward move, no
  # intervening authored non-merge commit, a clean re-merge reproduces the head tree) and the
  # rendered patch may legitimately differ, so `authored-digest-equal` prints `no`/`UNMEASURED`
  # there. So `proved` states which dimension carried.
  # EACH FIELD NAMES THE PREDICATE THAT MEASURED IT -- never the arm that happened to fire.
  # The mapping itself now lives in ONE place, `delta_proof_fields` (defined beside the delta
  # helpers above), so the writer and its pin cannot drift: `authored_unchanged` is a claim about
  # the AUTHORED DIGEST (only `patch`/`diff` measure it) and `conflicts` is a claim about a
  # RE-MERGE (only `lane` recomputes one, clause D). Keying BOTH on `patch|diff` was MEASURED as
  # a lie in one direction -- a `diff`-arm delta across a REBASED head prints
  # `zero-conflict=UNMEASURED` in its own triple while the record asserted `"conflicts":0`.
  # ⛔ AND THE SAME RULE APPLIES TO `from`, not just to these two fields (#3247 review, P1):
  # the arms do not all measure from the RECORD's head, so `from` is
  # `${DELTA_MEASURED_FROM:-$DELTA_FROM}` -- set by `delta_measured_from` on the arm that
  # actually carried. Writing the record's head there made a signed record claim an
  # authored-unchanged fact about a pair the run never measured (MEASURED: triple said
  # `authored-digest-equal=no commits=2` while the record said `authored_unchanged:true`).
  # `proved` always names the dimension that carried; `carried_from` keeps the RECORD's head.
  if [ "$DELTA" -eq 1 ]; then
    DIMENSION="none"
    case "$CARRY_ARM" in
      lane) DIMENSION="lane";;
      patch) DIMENSION="patch";;
      diff) DIMENSION="diff-bytes";;
    esac
    DELTA_PROOF="$(delta_proof_fields "$CARRY_ARM")"
    MINT_FIELDS="\"mint\":\"delta\",\"carried_from\":\"$ORIG_SHA\",\"carried_at\":\"$(date -u +%Y-%m-%dT%H:%M:%SZ)\",\"delta\":{\"from\":\"${DELTA_MEASURED_FROM:-$DELTA_FROM}\",\"to\":\"$SHA\",\"proved\":\"$DIMENSION\",${DELTA_PROOF}\"arm\":\"$CARRY_ARM\"},"
  fi
fi
EVIDENCE_FIELD=""
if [ -n "$EVIDENCE_VERIFIED" ]; then
  EVIDENCE_FIELD="\"evidence\":\"$EVIDENCE_VERIFIED\","
elif [ -n "$CARRY_EVIDENCE" ]; then
  EVIDENCE_FIELD="\"evidence\":\"$CARRY_EVIDENCE\","
fi
# ── #3400 — THE FINDING COUNT, and why it is a FIELD and not prose ─────────
# The gate has to be able to say WHAT is open. "verdict is not clean" is a state;
# "1 open P2" is a diagnosis a lane can act on. `findings` is the machine-readable
# half (an integer the gate can count and print) and `findings_note` the optional
# human half (severity detail, verbatim) — never parsed, so it cannot grow into a
# second grammar. Written ONLY for `not-clean`: a clean record that carried a
# `findings` field would be a clean verdict admitting an open finding.
FINDINGS_FIELD=""
if [ "$VERDICT" = "not-clean" ]; then
  # ⛔ THE WRITE RE-CHECKS THE SPELLING IT DEPENDS ON (review, P2-1). This field is
  # UNQUOTED on purpose — quoting it would change its JSON TYPE, and every reader
  # binds a number (`typeof record.findings === "number"`), so "quote it on write"
  # is not available here: it would retire the count the negative verdict exists to
  # carry. What IS available is to refuse to emit a value that would produce an
  # unparseable record, because the gate reads an unparseable record as NO RECORD —
  # the exact #3400 confusion. The input arm above canonicalises; this refuses if
  # that ever stops holding, so no future edit can write `"findings":007`.
  if ! [[ "$FINDINGS" =~ ^[1-9][0-9]*$ ]]; then
    echo "record-review.sh: refusing to write findings='$FINDINGS' — the field is emitted as an UNQUOTED JSON number, so a non-canonical spelling (leading zeros, sign, decimals) would make the whole record unparseable, and the merge gate reads an unparseable record as NO record. Nothing was recorded." >&2
    exit 2
  fi
  FINDINGS_FIELD="\"findings\":$FINDINGS,"
  if [ -n "$FINDINGS_NOTE" ]; then
    FINDINGS_FIELD="${FINDINGS_FIELD}\"findings_note\":\"$FINDINGS_NOTE\","
  fi
fi
# ── CARRY PROOF FIELDS (#10177) ───────────────────────────────────────────
# Written for EVERY carry, so `mint:"carried"` is never a bare claim: it names
# the arm that proved the artifact unchanged, the artifact as reviewed, and the
# delta the head added. `--check-carry` treats a carried record WITHOUT these as
# no record at all (see the unproven-carry arm above).
CARRY_FIELDS=""
if [ -n "$CARRY_ARM" ]; then
  CARRY_FIELDS="\"carry_arm\":\"$CARRY_ARM\","
  if [ -n "$CARRY_REVIEWED_DIFF" ]; then
    CARRY_FIELDS="${CARRY_FIELDS}\"reviewed_diff_sha256\":\"$CARRY_REVIEWED_DIFF\",\"reviewed_diff_source\":\"$CARRY_REVIEWED_SOURCE\","
  fi
  if [ -n "$CARRY_DELTA_DIFF" ]; then
    CARRY_FIELDS="${CARRY_FIELDS}\"carried_delta_sha256\":\"$CARRY_DELTA_DIFF\","
  fi
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
  # ⛔ A RECOVERED reviewed_at IS A LOWER BOUND, NOT A MINT TIME (#2872 review,
  # round 3). Carrying it forward verbatim and printing "preserved as the ORIGINAL
  # mint time" would launder a commit date into a mint time and drop the
  # `recovered-body` label at the same moment — the tortoise#7391 corruption this
  # whole arm exists to prevent. So a recovered predecessor falls into the honest
  # branch below, which says the mint time is NOT recoverable.
  PRIOR_RECOVERED=0
  if [ -f "$FILE" ] && grep -q '"mint":"recovered-body"' "$FILE"; then PRIOR_RECOVERED=1; fi
  if [ "$PRIOR_RECOVERED" -eq 0 ] && [ -n "$PRIOR_AT" ] && [ "$PRIOR_HEAD" = "$ORIG_SHA" ]; then
    REVIEWED_AT="$PRIOR_AT"
    echo "tortoise#7391 carry provenance: reviewed_at preserved as the original mint time $PRIOR_AT (mint=$([ "$DELTA" -eq 1 ] && echo delta || echo carried), carried_from=${ORIG_SHA:0:12}…)" >&2
  else
    if [ "$PRIOR_RECOVERED" -eq 1 ]; then
      echo "⚠️ tortoise#7391 / #2872: CARRIED record for ${REPO:-<no-repo>}#$PR whose predecessor was RECOVERED from a marker — that record's reviewed_at was a LOWER BOUND (the head commit's date), not a mint time, so it is NOT inherited. reviewed_at is the CARRY time; \`mint\`/\`carried_at\` say so." >&2
    else
      echo "⚠️ tortoise#7391: CARRIED record for ${REPO:-<no-repo>}#$PR and the ORIGINAL mint time is not recoverable (no record on disk names ${ORIG_SHA:0:12}… with a reviewed_at) — reviewed_at is the CARRY time, not the mint time; \`mint\`/\`carried_at\` say so." >&2
    fi
  fi
fi
if [ -n "$REPO" ]; then
  printf '{"pr":%d,"head_sha":"%s",%s%s%s%s%s%s"verdict":"%s","repo":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$SHA" "$MB_FIELD" "$DIFF_FIELD" "$MINT_FIELDS" "$CARRY_FIELDS" "$EVIDENCE_FIELD" "$FINDINGS_FIELD" "$VERDICT" "$REPO" "$REVIEWED_AT" > "$TMP"
else
  printf '{"pr":%d,"head_sha":"%s",%s%s%s%s%s%s"verdict":"%s","reviewed_at":"%s"}\n' \
    "$PR" "$SHA" "$MB_FIELD" "$DIFF_FIELD" "$MINT_FIELDS" "$CARRY_FIELDS" "$EVIDENCE_FIELD" "$FINDINGS_FIELD" "$VERDICT" "$REVIEWED_AT" > "$TMP"
fi
# ── IDEMPOTENT SAME-HEAD WRITE (#1709 rec 7) ─────────────────────────────
# The record this run would write is already on disk with the SAME deterministic
# identity (record_identity, above), so a duplicate execution is a NO-OP: do not
# rewrite it. This is what keeps `reviewed_at` — the audit trail's only join to
# the authorising dispatch — stable across a duplicate, and it makes the second
# execution's result BYTE-IDENTICAL to the first's rather than merely equivalent.
# The legacy-migration and evidence-post blocks below still run: they are already
# idempotent, and skipping them would only make a duplicate STRAND the legacy key
# (the failure this whole block exists to avoid) — the record file is the one
# side effect that was not idempotent. ⛔ The no-op arm skips ONLY the write: the two
# blocks below are UNCONDITIONAL and still run, which is what keeps a duplicate from
# STRANDING the legacy key. That half is pinned by record-review.test.sh §15.8 (a
# same-head duplicate with a legacy key present must still remove it).
if [ -f "$FILE" ] && [ "$(record_identity "$FILE")" = "$(record_identity "$TMP")" ]; then
  rm -f "$TMP"
  echo "#1709 rec 7 idempotent: $REPO#$PR already records verdict=$VERDICT at head ${SHA:0:12}… with the same binding — record NOT rewritten (reviewed_at preserved)" >&2
else
  mv "$TMP" "$FILE"
fi
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
  # ── #3400 — THE NEGATIVE MARKER, and why its trailer is APPENDED ─────────
  # The marker's leading shape is a contract with `ai-review-gate` (tortoise
  # .github/workflows/ai-review-gate.yml regex-matches it) and with this script's
  # own prior-marker greps. Splicing `findings=` into that prefix would change the
  # shape every one of those parsers reads. So the trailer goes AFTER `(<repo>)`,
  # where the only consequence is that those parsers do not certify the line as
  # clean — which is the CORRECT outcome for a NOT CLEAN record: the merge gate
  # must not accept it. `--recover-body` understands the trailer (see RB_RE) and
  # is the reader that brings it back intact.
  if [ "$VERDICT" = "not-clean" ]; then
    MARKER="${MARKER} findings=${FINDINGS}"
    if [ -n "$FINDINGS_NOTE" ]; then
      MARKER="${MARKER} note=${FINDINGS_NOTE}"
    fi
  fi
  if [ -n "$GATE_KEY" ]; then
    SIG="$(printf '%s' "$MARKER" | command openssl dgst -sha256 -hmac "$GATE_KEY" 2>/dev/null | awk '{print $NF}' || true)"
    if [ -n "$SIG" ]; then
      MARKER="${MARKER} sig=${SIG}"
      MARKER_SIGNED=1
    else
      echo "⚠️ could not compute marker signature (openssl?) — posting unsigned marker; ai-review-gate will fail" >&2
      MARKER_SIGNED=0
    fi
  else
    echo "⚠️ AI_REVIEW_GATE_KEY not configured (env or ~/.pi/agent/.ai-review-gate-key) — posting unsigned marker; ai-review-gate required check will fail. Configure the key to match the repo secret." >&2
    MARKER_SIGNED=0
  fi
  # Read the PR body — distinguish a genuinely EMPTY body (post marker-only)
  # from a GET FAILURE (skip the post loudly — never clobber the description).
  if BODY="$(command gh api "repos/$REPO/pulls/$PR" --jq .body 2>/dev/null)"; then
    [ "$BODY" = "null" ] && BODY=""
  else
    # A FAILED READ IS NOT A REASON TO LOSE THE EVIDENCE (defect A). The marker is
    # already built and the record already written, so the bytes go to the PENDING
    # file first: a later `--flush-pending` (or any later run of this PR) delivers
    # them without a second review. Exit 5 names the state instead of reporting
    # success over an invisible record.
    marker_pending_write "$(marker_pending_file "$REPO" "$PR")" "$MARKER" || echo "⚠️ body-marker: could NOT persist the pending marker at $(marker_pending_file "$REPO" "$PR") — ⛔ THE BYTES ARE NOT ON DISK, so the --flush-pending remedy this arm prints below WILL FIND NOTHING and will report success (it answers 'nothing pending … Nothing was written', exit 0). The marker is reproduced HERE so it is not lost: paste the line between the >>> markers into the PR body by hand if gh is throttled. >>> $MARKER <<<" >&2
    # ⛔ THE DURABLE CHANNEL IS ATTEMPTED HERE, BEFORE THE exit 5 (agent-infra#3168
    # review P2). This arm and the PATCH-failure arm below are the ONLY scenarios
    # the durable channel exists for, and both used to `exit 5` before reaching it —
    # so the copy that survives a body-channel failure was never created by the one
    # run that needed it. The permission split makes it real: the body post needs
    # `pull-requests:write` while the comment needs `issues:write`, so a token
    # holding the latter but not the former fails the body post and could have
    # delivered the comment. Best-effort: it cannot change this exit code.
    # ⛔ THE CALL, not just the paragraph above (measured: the paragraph shipped
    # WITHOUT it, so the arm this channel exists for still exited 5 having
    # published nothing — suite vector 14.1d(e) is the discriminator).
    post_marker_comment "$REPO" "$PR" "$MARKER" || true
    # ⛔ THE NOUN CARRIES NO SIGNEDNESS CLAIM (#3168 re-review P2): this arm is
    # reached with MARKER_SIGNED=0 too (:4831-4834 — with no gate key the `else`
    # branch warns and sets MARKER_SIGNED=0, then execution CONTINUES to the body
    # read below), so "the signed marker" named a property these bytes need not
    # have. It says "the marker".
    echo "⛔ body-marker-unposted: could not read the PR body of $REPO#$PR (gh refused the GET — ⛔ this line does NOT assert WHICH cause: the error text is discarded, so a transient API failure, a throttled token, and a permanent 404 for a wrong PR number or a repo this token cannot see all land here), so the marker was NOT written into the PR body — the record is saved. ⛔ THIS MESSAGE COVERS THE PR BODY ONLY. It is deliberately not a claim about whether ai-review-gate can read the evidence from a PR COMMENT: the comment channel is a separate call that reports on its OWN line when it has something to report, and is SILENT when it withheld the post by design (an UNSIGNED marker is never published as a comment) or when an admitted comment already carries the marker. Admission there is decided by the gate (OWNER/MEMBER/COLLABORATOR authors only). ⛔ WHETHER THESE BYTES ARE ON DISK DEPENDS ON THE PERSIST WARNING ABOVE: if that warning did NOT appear, the marker is kept in $(marker_pending_file "$REPO" "$PR") and a later: record-review.sh --flush-pending $PR $REPO — delivers the BODY copy WITHOUT a new review IF the cause was transient (a PERMANENT cause fails that retry the same way). If it DID appear, NOTHING was written, --flush-pending will answer 'nothing pending', and the marker text exists ONLY inside that warning line — copy it from there." >&2
    exit 5
  fi
  # Idempotent append — post even when the body is EMPTY (an empty body must
  # not silently skip the evidence post; the gate would fail with no trace).
  MISSING=""
  # ⛔ LINE-ANCHORED (`-x`), matching the gate's own `^…$` admission of a body
  # marker (`ai-review-gate.yml:638`). Unanchored `-qF` matched the marker as a
  # SUBSTRING anywhere, so a body that merely QUOTES the marker mid-line (a lane
  # citing the attestation, a review comment pasted in) suppressed the append and
  # set MARKER_PRESENT below while the gate rejected the very same line — the
  # evidence the gate needs then never got posted. Same class as the comment-side
  # fix in this change, applied to the channel that was already shipping.
  if ! grep -qxF -- "$MARKER" <<<"$BODY"; then
    MISSING="$MARKER"
  fi
  # #633: the body as it stands AFTER this run's post attempt — the stale-run
  # remediation below must decide on the body the gate will actually read.
  BODY_NOW="$BODY"
  if [ -n "$MISSING" ]; then
    # PERSIST FIRST, POST SECOND (fresh-review P2). The header promises the bytes
    # survive "a failed POST, a killed shell or a 403 window" — true only if the
    # pending file exists BEFORE the PATCH, so a shell killed mid-PATCH (a lane
    # reap, a timeout) leaves a saved record whose marker is still recoverable.
    if ! marker_pending_write "$(marker_pending_file "$REPO" "$PR")" "$MISSING"; then
      echo "⚠️ body-marker: could not persist the pending marker at $(marker_pending_file "$REPO" "$PR") — if the post below fails, copy this line from this message: $MISSING" >&2
    fi
    if [ -n "$BODY" ]; then
      NEWBODY="${BODY}

${MISSING}"
    else
      NEWBODY="$MISSING"
    fi
    if jq -n --arg body "$NEWBODY" '{body: $body}' 2>/dev/null \
        | command gh api -X PATCH "repos/$REPO/pulls/$PR" --input - >/dev/null 2>&1; then
      echo "review evidence posted to $REPO#$PR body"
      BODY_NOW="$NEWBODY"
      command rm -f "$(marker_pending_file "$REPO" "$PR")" 2>/dev/null || true
    else
      # ⛔ DEFECT A (measured 2026-11-03, tortoise#10677 during a 403 window on the
      # shared 5000/hr token). This used to print "record still saved" and exit 0:
      # the per-box record existed, CI saw nothing, and `ai-review-gate` correctly
      # refused the PR — a correctly reviewed PR blocked by a bookkeeping failure,
      # with the ONLY local record of the failure on stderr. It is now a NAMED
      # non-zero state, and the marker survives on disk so delivery can be retried
      # without re-recording (which would dilute the evidence).
      marker_pending_write "$(marker_pending_file "$REPO" "$PR")" "$MISSING" || echo "⚠️ body-marker: could NOT persist the pending marker at $(marker_pending_file "$REPO" "$PR") — ⛔ THE BYTES ARE NOT ON DISK, so the --flush-pending remedy printed below WILL FIND NOTHING and will report success. The marker is reproduced HERE so it is not lost: paste the line between the >>> markers into the PR body by hand. >>> $MISSING <<<" >&2
      # Same reasoning as the read-failure arm above (#3168 review P2): the PATCH
      # was refused, so the durable channel is the one that can still carry the
      # marker's bytes. Attempted BEFORE the exit, and "$MISSING" not "$MARKER" — it
      # is the exact line this run tried to deliver.
      post_marker_comment "$REPO" "$PR" "$MISSING" || true
      # ⛔ NO SIGNEDNESS CLAIM IN THE MESSAGE BELOW (#3168 re-review P2): like the
      # read-failure arm, this one is reached with MARKER_SIGNED=0 as well
      # (:4831-4834 — no gate key warns and CONTINUES), so "the signed marker" named
      # a property the bytes on this path need not have. The marker is called "the
      # marker" — the caller's own warning line already said loudly whether it was
      # signed.
      echo "⛔ body-marker-unposted: the marker for $REPO#$PR could NOT be PATCHed into the PR body (gh/API refused — ⛔ this line does NOT assert WHICH cause: the PATCH's error text is discarded, so a spent token budget, a 403, a 5xx and a permanent 404/422 all land here). The record IS saved at $FILE. ⛔ THIS MESSAGE COVERS THE PR BODY ONLY. It is deliberately not a claim about whether ai-review-gate can read the evidence from a PR COMMENT: the comment channel is a separate call that reports on its OWN line when it has something to report, and is SILENT when it withheld the post by design (an UNSIGNED marker is never published as a comment) or when an admitted comment already carries the marker. Admission there is decided by the gate (OWNER/MEMBER/COLLABORATOR authors only). The BODY PATCH is what fires the 'edited' event that RE-RUNS the gate, so this retry is still owed." >&2
      echo "   ⛔ THE PERSIST WARNING ABOVE DECIDES THIS LINE'S TRUTH: if it did NOT appear, the marker is kept verbatim in $(marker_pending_file "$REPO" "$PR") — deliver it with: record-review.sh --flush-pending $PR ${REPO}   (no new review, no new record, no re-record). If it DID appear, nothing is on disk, that flush will find nothing, and the marker text exists ONLY inside that warning line." >&2
      exit 5
    fi
  fi

  # ── Durable channel: the SAME signed marker as an append-only PR COMMENT ──
  # (#1224 producer half.) The doctrine, the cross-repo byte-identity contract and
  # the declared residuals all live at post_marker_comment() — one chokepoint, so a
  # new call site cannot quietly skip the unsigned guard or the admission set.
  post_marker_comment "$REPO" "$PR" "$MARKER" || true

  # ── Stale gate-run remediation (#633) ──────────────────────────────────
  # A completed pre-evidence FAILURE (the push-triggered run that evaluated
  # the body before this marker existed) does not durably block a merge once
  # a later SUCCESS for the same head exists (verified empirically, #633) —
  # but the FAILURE keeps showing a red ai-review-gate row in the rollup
  # until something re-evaluates, and when the gate's NEWEST run on the head
  # is completed and red the documented remedy — "re-run record-review.sh to
  # retry" — used to be a silent no-op: the marker is already in the body, so
  # no PATCH fires, no `edited` event, and no fresh gate run (tortoise PR
  # #2698 thrashed on this for 40 min). User tokens cannot rewrite the stale
  # run's conclusion (PATCH /check-runs/{id} → 403, GitHub-App-only) nor
  # re-request it (POST /check-runs/{id}/rerequest → 404 for Actions runs),
  # but CAN re-run the Actions job (POST /actions/jobs/{id}/rerun — verified
  # #633). So when the head's newest gate run is NOT in flight AND red (the
  # allow-list polarity, below), re-run it here: the re-run re-reads the PR
  # body live, so with the signed marker
  # present it replaces the stale red attempt with a fresh run (for GitHub
  # Actions the check-run id IS the job id). A newer SUCCESS for the name is
  # the normal green end-state (no rerun — would just churn Actions jobs); a
  # deliberately stale record (--force-stale) is never remediated (its gate
  # state is unresolvable by design and a rerun in the PR's concurrency group
  # could cancel the real head's in-flight gate run). The gate's check-run
  # name is repo-specific — override AI_REVIEW_GATE_CHECK_NAME for consumers
  # that renamed their required check. A check-run NAME is an arbitrary
  # string: only leading/trailing padding is trimmed, INTERIOR whitespace is
  # preserved (review finding 2). Best-effort — NEVER fails the record.
  #
  # GATED ON THE **SIGNED** MARKER (#633 review finding 3): `MARKER` carries
  # ` sig=<hmac>` iff a key signed it. An UNSIGNED marker (no
  # AI_REVIEW_GATE_KEY) can never satisfy the gate, so re-running against it
  # re-evaluates to a guaranteed red — exactly the churn this guard exists to
  # prevent, and exactly what a text-only `MARKER_PRESENT` gate did.
  MARKER_PRESENT=0
  if [ "$MARKER_SIGNED" = "1" ] && grep -qxF -- "$MARKER" <<<"$BODY_NOW"; then
    MARKER_PRESENT=1
  fi
  if [ "$MARKER_PRESENT" = "1" ] && [ "$FORCE_STALE" -ne 1 ]; then
    # Trim only LEADING/TRAILING padding (#633 review finding 2). A check-run
    # NAME is an arbitrary string, and `tr -d '[:space:]'` — correct for the
    # HMAC key it was copied from — also deletes INTERIOR whitespace, silently
    # zeroing every name that contains it (`python-ci / test` is a real name on
    # this fleet). Interior whitespace is meaningful and must survive.
    GATE_CHECK="${AI_REVIEW_GATE_CHECK_NAME:-ai-review-gate}"
    GATE_CHECK="$(printf '%s' "$GATE_CHECK" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    : "${GATE_CHECK:=ai-review-gate}"
    NEWEST_RED_ID=""
    # ⛔ THE TRANSPORT IS THE WHOLE BUG THIS FIX EXISTS FOR (#633 review
    # finding 1): `gh api` switches to POST as soon as ANY `-f`/`-F` parameter
    # is added, and `GET /commits/{ref}/check-runs` is GET-only — so a
    # parameterized call with no `-X GET` answers `404 Not Found`. That made
    # the `if` below FALSE on every production invocation, left NEWEST_RED_ID
    # empty, and turned the rerun into dead code while printing a false
    # "gh/API failure" warning. So the read carries an EXPLICIT `-X GET`; the
    # suite's gh stub models the method now, so a regression reddens it instead
    # of passing silently. Parameters go through `-f` (NOT a hand-built query
    # string) so gh PERCENT-ENCODES them: `check_name` is an arbitrary string,
    # and a name with interior whitespace makes a raw query string malformed
    # (measured: a literal space in the URL → PROTOCOL_ERROR, while
    # `-X GET -f check_name='python-ci / test'` answers 200 — finding 2).
    # The commit check-runs payload is read RAW so a query failure is
    # distinguishable from "no red run" (the #405 convention: a transient
    # API failure must warn loudly and skip, never read as nothing-to-do).
    # The server-side check_name filter keeps the payload to the gate's own
    # runs (a commit can carry >100 check runs across a big CI matrix — an
    # unfiltered page could push the true newest gate run out of view).
    if GATE_JSON="$(command gh api -X GET "repos/$REPO/commits/$SHA/check-runs" -f check_name="$GATE_CHECK" -f per_page=100 -f filter=all 2>/dev/null)"; then
      # Newest run for the gate check name across ALL statuses, then judge it
      # by the repo's ALLOW-LIST POLARITY (#633 review finding 1; AGENTS.md
      # §"Reading verification state" step 4, and the same predicate
      # target_head_red above already uses). Only success/neutral/skipped are
      # green and cancelled/stale are non-red; EVERY OTHER conclusion is RED —
      # including one GitHub has not documented and a null one. A closed
      # red-list (failure/cancelled/timed_out/action_required) read an
      # unrecognised or null conclusion as "not red AND not suspicious" — no
      # rerun and no warning, the silent no-op #633 exists to close.
      #
      # "In flight" is the NAMED set only. A queued/in_progress run (a rerun
      # the remediation itself fired, or the `edited` run a fresh PATCH just
      # started) is already re-evaluating the body, and re-running the older
      # red behind it would start a second job whose per-PR cancel-in-progress
      # cancels the in-flight fresh run — forever. An unrecognised STATUS is
      # NOT in that set: it falls through to the conclusion, and a null
      # conclusion is RED, exactly as target_head_red decides it (gating on
      # "no conclusion" is the #1353 fail-open). `select(. != null)` keeps an
      # empty gate-name match from minting a literal `null` id. The local name
      # filter is a belt over the server filter, and $gate arrives via --arg —
      # no jq-program interpolation.
      # ⛔ `cancelled` STAYS IN THE NON-RED SET — a recorded repo rule, pinned by
      # `record-review.test.sh` case 14.14c ("cancelled is non-red per the repo
      # rule") and by AGENTS.md §"Reading verification state" step 4. A required
      # check does need a green conclusion, so a head whose newest attempt is
      # `cancelled` IS blocked — but flipping that predicate here would silently
      # reverse the ruling for every consumer of the polarity. It is a REOPEN, not
      # an edit: the evidence (tortoise #10406 had 4 of its newest 8 gate runs
      # `cancelled`; #10443 newest was `cancelled` at 17:39 until a job rerun
      # rescued it at 17:47; #10437 `cancelled` at 18:00 → green at 18:04) is
      # recorded in the PR body and in tortoise#10399, and the decision stays where
      # it lives. Deliberately UNCHANGED.
      if ! NEWEST_RED_ID="$(printf '%s' "$GATE_JSON" \
        | jq -r --arg gate "$GATE_CHECK" \
          '[.check_runs[] | select(.name == $gate)] | sort_by(.id) | reverse | .[0] | select(. != null) | select(.status != "queued" and .status != "in_progress" and .status != "waiting" and .status != "requested" and .status != "pending") | select((.conclusion // "") as $c | ($c != "success" and $c != "neutral" and $c != "skipped" and $c != "cancelled" and $c != "stale")) | .id' \
      )"; then
        # A gh-200 whose body fails the jq stage is its own failure class
        # (payload shape change, broken jq) — warn loudly, never read as
        # "no red run" (#405 applies to every stage of the read).
        echo "⚠️ could not parse the check-runs payload for $SHA (check_name=$GATE_CHECK) — stale-run re-run skipped; record still saved. Re-run record-review.sh to retry." >&2
        NEWEST_RED_ID=""
      elif [ "$(printf '%s' "$GATE_JSON" | jq -r --arg gate "$GATE_CHECK" '[.check_runs[] | select(.name == $gate)] | length' 2>/dev/null || echo 0)" = "0" ]; then
        # The gate has NO runs on this head (the server already filtered to
        # the name, so an empty payload means the workflow never ran here OR
        # AI_REVIEW_GATE_CHECK_NAME is wrong). One cheap unfiltered count
        # query tells the two apart — other checks exist → loud rename hint
        # (a wrong override must never read as "nothing to remediate");
        # no checks at all → stay silent (nothing has run yet).
        if ALL_JSON="$(command gh api "repos/$REPO/commits/$SHA/check-runs?per_page=1" 2>/dev/null)"; then
          TOTAL_RUNS="$(printf '%s' "$ALL_JSON" | jq -r '(.total_count // (.check_runs | length))' 2>/dev/null || echo 0)"
          case "$TOTAL_RUNS" in ''|*[!0-9]*) TOTAL_RUNS=0 ;; esac
          if [ "$TOTAL_RUNS" -gt 0 ]; then
            echo "⚠️ no check run named '$GATE_CHECK' found on $SHA ($TOTAL_RUNS checks total) — verify AI_REVIEW_GATE_CHECK_NAME; stale-run re-run skipped" >&2
          fi
        fi
      fi
    else
      echo "⚠️ could not read check runs for $SHA (gh/API failure?) — stale-run re-run skipped; record still saved. Re-run record-review.sh to retry." >&2
    fi
    # Shape-guard the id before it reaches gh argv (ids come from GitHub
    # JSON .id fields, but an errored query must never read as a job id).
    if [ -n "$NEWEST_RED_ID" ] && [[ "$NEWEST_RED_ID" =~ ^[0-9]+$ ]]; then
      if command gh api -X POST "repos/$REPO/actions/jobs/$NEWEST_RED_ID/rerun" >/dev/null 2>&1; then
        echo "re-ran stale $GATE_CHECK run (job $NEWEST_RED_ID) — the fresh run re-evaluates the body with the recorded marker"
      else
        echo "note: could not re-run stale $GATE_CHECK job $NEWEST_RED_ID (permissions/state?) — record saved; the gate re-evaluates only on the next push or PR-body edit, so push a commit or re-record to retry" >&2
      fi
    fi
  fi
else
  if [ -n "$REPO" ]; then
    # Same defect-A shape one level out: a record whose evidence channel is
    # unreachable (no gh on PATH) is a record CI cannot see. NO PENDING WRITE HERE:
    # MARKER is built INSIDE the gh-available block above, so writing it here
    # persists an EMPTY file (a fresh review measured exactly that, and the flush
    # then "delivered" nothing and deleted it). The next run WITH gh rebuilds the
    # marker from the record and posts it, so nothing is lost.
    # ⛔ THE SAME FALSE NOUN ON THE THIRD EXIT-5 ARM (#3168 re-review, cycle 2): this
    # message used to say "the signed marker", and here it is false TWICE — no gate
    # key means nothing was signed, and the whole marker is built INSIDE the
    # gh-available block above, so on THIS arm no marker was even constructed (the
    # paragraph above says exactly that about the pending file). It now says that.
    echo "⛔ body-marker-unposted: the gh CLI is missing, so no marker for $REPO#$PR was posted — the record is saved at $FILE but the ai-review-gate required check cannot see it. Install gh and re-run the recorder at this head: it rebuilds the marker from the record and posts it (no new review, no re-record)." >&2
    exit 5
  fi
  echo "⚠️ record-review: evidence post skipped (gh CLI missing or REPO undetectable) — the record is saved, but the ai-review-gate required check will fail until evidence is posted manually." >&2
fi
fi # /main guard (#513)
