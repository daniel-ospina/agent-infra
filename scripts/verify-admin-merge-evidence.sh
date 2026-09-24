#!/usr/bin/env bash
# verify-admin-merge-evidence.sh — is this admin merge JUSTIFIED? (#984)
#
# The argv-level layer's decision rule. `scripts/gh-shim/gh` calls it when a
# RESOLVED argv is an admin merge, and it is available to the TypeScript gate so
# the certifying contract has one home rather than two that can drift.
#
# Usage:
#   verify-admin-merge-evidence.sh <PR> [--repo owner/repo] [--head <sha>]
#   verify-admin-merge-evidence.sh --body-file <file> --head <sha>   (offline: one body)
#
# Exit: 0 = a certifying evidence comment exists FOR THE CURRENT HEAD; 1 = it does not.
#
# The contract, per comment — never across comments, because a marker in one and a
# verdict in another must not add up to a certificate:
#   <!-- admin-merge-safety: <HEAD> -->   the marker, bound to the CURRENT head
#   PR head: <HEAD>                       the body names the same revision
#   main compared (union of …             the comparison actually happened
#   … unique to this PR: 0                the residual is zero
#
# Env:
#   AGENT_GH_REAL   the real gh binary (set by the shim; default: `gh`). It must NOT
#                   resolve back to the shim, or the check would recurse.
set -uo pipefail

PR=""; REPO=""; HEAD=""; BODY_FILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO="${2:-}"; shift 2 ;;
    --head) HEAD="${2:-}"; shift 2 ;;
    --body-file) BODY_FILE="${2:-}"; shift 2 ;;
    --help|-h) awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0 ;;
    -*) printf 'verify-admin-merge-evidence: unknown option %s\n' "$1" >&2; exit 2 ;;
    *) PR="$1"; shift ;;
  esac
done

GH="${AGENT_GH_REAL:-gh}"
repo_args=()
[ -n "$REPO" ] && repo_args=(--repo "$REPO")

if [ -n "$BODY_FILE" ]; then
  [ -r "$BODY_FILE" ] || { printf 'verify-admin-merge-evidence: no body at %s\n' "$BODY_FILE" >&2; exit 1; }
  [ -n "$HEAD" ] || { printf 'verify-admin-merge-evidence: --body-file needs --head\n' >&2; exit 2; }
else
  [ -n "$PR" ] || { printf 'verify-admin-merge-evidence: a PR number or --body-file is required\n' >&2; exit 2; }
  case "$PR" in *[!0-9]*) printf 'verify-admin-merge-evidence: PR must be numeric (got %s)\n' "$PR" >&2; exit 2 ;; esac
  # The head is re-resolved HERE, not taken from the command: a merge must be
  # justified for the revision that is about to land, not for an older one.
  if [ -z "$HEAD" ]; then
    HEAD="$("$GH" pr view "$PR" ${repo_args[@]+"${repo_args[@]}"} --json headRefOid --jq .headRefOid 2>/dev/null)"
  fi
fi

# A head that is not a plain SHA is not something this contract can bind to, and
# interpolating it into the jq program below would be an injection surface.
case "${HEAD:-}" in
  ''|*[!0-9a-fA-F]*) printf 'verify-admin-merge-evidence: no usable head sha (got %s)\n' "${HEAD:-<empty>}" >&2; exit 1 ;;
esac

# One jq pass, ONE comment at a time: `select` appears inside the per-comment
# pipeline, so every clause must hold for the SAME comment. Literal phrases use
# `contains`; the clauses whose SHAPE carries the guarantee (provenance, the
# count line, the attribution) use `test`, because a substring cannot express
# "a well-formed zero".
#
# CLAUSE 4 (#1388): the producer RENAMED this field in bcbb7df (2026-09-17,
# #3756/PR #1147) from `unique to this PR: 0` to `blocked by the decision: 0`,
# in four places, and both gates kept requiring the OLD name — which refused
# every admin merge fleet-wide for six days. The producer's vocabulary is the
# contract; the gate follows it. Verified against the emission site
# (scripts/admin-merge.sh:2250) before writing it here.
#
# CLAUSE 5 (#1388 §3): the zero must be MEASURED and COMPARABLE, not merely
# printed — otherwise swapping a strong claim for a weaker one would be a net
# LOOSENING of this gate.
#   * `PR=0 | main=0` (the attribution line, admin-merge.sh:3319) is the
#     positive test that the parser dropped NO token. A clipped set is not a
#     measured zero, so a zero over it does not certify.
#   * when BOTH counts are zero — `PR failing: 0 | main failing: 0` — the
#     comparison was VACUOUS, so the positive line `lane parity: PR ⊇ main`
#     (value built at admin-merge.sh:3354, printed at :3412) is required.
#     `lane parity: NOT ESTABLISHED` therefore does NOT certify — #1319's own
#     rule, a vacuous comparison is not comparable without parity. Vacuity is
#     read from the COUNTS (see below), not from the producer's descriptive
#     `measured sets:` line.
# THE CLAUSES MIRROR THE PRODUCER'S REAL EMISSION AND ARE SHAPE-CHECKED, not
# substring-matched. The first cut of this change used bare `contains` for the
# provenance, count and attribution clauses, and the main-only suite immediately
# showed three fail-opens it had introduced: `union of 1 banana` (provenance
# unverified), `blocked by the decision: 0.5` / `01` (the zero unbounded), and a
# bare `PR=0 | main=0` that also matches the unrelated `Failing runs examined:`
# line. A substring test cannot say "this is a well-formed zero"; a regex can, and
# this is exactly the precision the retired shim implementation had.
#
# `\b` is NOT enough to bound the zero, which is worth stating because it looks
# like it is: in `0.5` there IS a word boundary between `0` and `.`, so `0\b`
# accepts a fractional residual. The clause therefore requires the zero to be
# followed by whitespace or end-of-line — which is precisely how the producer
# emits it (`printf 'PR failing: %s | main failing: %s | blocked by the decision:
# 0\n'`, admin-merge.sh:2250), verified at the emission site.
#
# The provenance lane is spelled `( of .+)?:` GREEDILY and not a character class:
# a lane may be named by a workflow NAME, and `gh` accepts names containing `:`
# and `()` — `--workflow 'CI: tests'` and `--workflow 'tests (unit)'` both emit
# valid rail evidence, and a narrow class refused a legitimate merge (cycle-3
# review of the retired implementation). The tolerance is carried over, not
# re-invented.
#
# PARITY IS SHAPE-CHECKED, AND THE TOLERATED PARENTHETICAL IS THE PRODUCER'S OWN SHAPE.
# Three rounds of this clause, each closing one spelling and leaving the class open:
#   (1) a bare prefix test accepted `lane parity: PR ⊇ main is NOT established — …`;
#   (2) requiring the em dash accepted `lane parity: PR ⊇ main — NOT established: …`,
#       because an em dash is a SEPARATOR, not a truth value;
#   (3) requiring the producer's positive sentence plus a three-spelling negation
#       DENY-LIST accepted `… (parity family: … on main — Not established: …)` — a
#       case-sensitive deny-list is defeated by `Not established` / `not ESTABLISHED`,
#       and any contradiction word it does not name slips through. A deny-list of
#       spellings is the same mistake as (1) and (2) one level up.
# So the tolerated trailing text is now the PRODUCER'S OWN PARENTHETICAL SHAPE
# (`(parity family: <prefix>*; <n> shard(s) on the PR side, <m> on main)`, built at
# admin-merge.sh:3354 and pinned in §6 of the contract suite), the line must END
# there, and TWO STRUCTURAL guards replace the spelling contest:
#   (a) EVERY PARITY STATEMENT MUST BE THE POSITIVE ONE. Not "the first parity line must
#       be positive and any other is refused" — a verifier pass found that a prefix
#       lookahead is satisfied by a SECOND line that repeats the positive prefix and
#       then contradicts (`lane parity: PR ⊇ main — NOT COMPARABLE: …`), and then that a
#       LINE-ANCHORED collection still missed a contradictory statement that was not
#       line-initial (`-  lane parity: …`, `NOTE lane parity: …`). The guard is thus a
#       collection test over every occurrence ANYWHERE, each of which must match the
#       full positive pattern (line-end anchor included) — so the class is closed for
#       every vocabulary and every position, not just the spellings a blacklist names.
#   (b) THE PREFIX CANNOT CARRY A SECOND COUNTS TAIL or a nested template: no `;` in
#       the prefix (so `… test*; NOT COMPARABLE …; 3 shard(s) …` cannot ride along), and
#       at most ONE `parity family:` occurrence per parity statement (so
#       `… (parity family: FAKE) (parity family: test*; 3 shard(s) …)` cannot).
#       THE `;` BAN IS A CONSTRAINT ON THE LANE-JOB PREFIX: a job family whose name
#       contains `;` would emit a line this gate refuses (fail-closed, but a refusal of
#       legitimate evidence). The fleet default is `test`; an operator setting
#       ADMIN_MERGE_LANE_JOB_PREFIX must avoid `;` until the producer validates it
#       (filed: the producer accepts any string). Control characters and the Unicode
#       line separators are excluded for the same reason.
#
# AND THE FILTER MUST BE COMPILABLE BY THE ENGINE THAT ACTUALLY RUNS IT LIVE. That is
# not the same engine as the offline path, and a verifier pass caught this the hard way:
# `--body-file` tests run under the system `jq` (Oniguruma, lookaround supported), while
# the LIVE path is `gh … --jq`, i.e. gh's embedded gojq over Go/RE2 — which REJECTS
# lookahead. The first cut of guard (b) used `(?!parity family:)`, which made the live
# path fail to compile the filter at all: `could not read the PR comments`, exit 1, for
# EVERY certificate — the six-day outage class, reintroduced by this branch, with all 67
# offline assertions green. So guard (b) is expressed as an OCCURRENCE COUNT instead, and
# §8 of the contract suite refuses any lookaround or backreference in this filter.
#
# WHAT THIS STILL CANNOT DO, stated rather than papered over: a hand-crafted body can
# put ARBITRARY PROSE inside the producer's parenthetical prefix. That is the same
# limit as hand-typing the counts — the contract is text, and no agent-side check can
# prove a comparison ran (see `evidenceBodyIsCertifying`'s docstring). What the clause
# does close is every path by which the PRODUCER'S OWN vocabulary says "this was not a
# comparison", which is the fail-open this lane exists to prevent.
#
# VACUITY IS DERIVED FROM THE COUNTS, NOT FROM THE PRODUCER'S DESCRIPTIVE LINE, and
# this is a fail-open that BOTH reviewers of the first revision reproduced
# independently. Clause 5 originally treated a body as vacuous when it contained
# `measured sets: PR failing` — a line whose only role is to DESCRIBE the state. A
# body stating the same zeros (`PR failing: 0 | main failing: 0`) with that one line
# deleted, renamed or reformatted therefore certified with NO parity statement at
# all. A requirement keyed on a deletable DESCRIPTION is a requirement an editor can
# delete; the two zeros are the condition itself, so the counts are what is tested.
#
# THE COUNTS ARE CANONICAL, and that is not pedantry: a second review round found
# that `PR failing: 00 | main failing: 0` satisfied a `[0-9]+` count while MISSING a
# literal-`0` vacuity test, so a semantically vacuous body certified with no parity
# line. `(0|[1-9][0-9]*)` is the spelling an integer HAS (`%s` of a computed count
# never carries a leading zero, admin-merge.sh:2250), and the vacuity test is
# additionally written `0+` as a second, independent line of defence.
#
# `contains("<!-- admin-merge-safety: ")` is kept WITHOUT the head on purpose: it is
# the literal the drift-pin extracts and checks against a REAL capture, and the
# head-bound literals are substituted at runtime so they cannot be pinned that way.
# The STATIC parts of those head-bound literals are pinned against the producer's
# evidence emission in the suite's §6.
#
# The refusal vocabulary (`CLIPPED`, `NOT COMPARABLE`, `UNATTRIBUTABLE`) is
# deliberately NOT matched: the attribution area prints those words as
# UNCONDITIONAL explanatory prose in every evidence comment, including the clean
# ones, so a bare `contains` on them would refuse every certificate.
CLAUSE_FILTER='(contains("<!-- admin-merge-safety: '"$HEAD"' -->"))
  and (contains("PR head: '"$HEAD"'"))
  and (contains("<!-- admin-merge-safety: "))
  and (test("main compared \\(union of [0-9]+ runs?( of .+)?\\):"))
  and (test("PR failing:\\s*(0|[1-9][0-9]*)\\s*\\|\\s*main failing:\\s*(0|[1-9][0-9]*)\\s*\\|\\s*blocked by the decision:\\s*0([ \\t\\r\\n]|$)"))
  and (test("PR=0 \\| main=0\\.([ \\t\\r\\n]|$)"))
  and ((test("PR failing:\\s*0+\\s*\\|\\s*main failing:\\s*0+\\s*\\|") | not)
       or (test("(^|\\n)[ \\t]*lane parity: PR ⊇ main — the PR executed every test shard main'"'"'s lane executed( \\(parity family: [^;\\n[:cntrl:]\\x{2028}\\x{2029}]*; [0-9]+ shard\\(s\\) on the PR side, [0-9]+ on main\\))?[ \\t]*(\\n|$)")
           and ([match("lane parity:[^\\n]*"; "g") | .string
                 | test("(^|\\n)[ \\t]*lane parity: PR ⊇ main — the PR executed every test shard main'"'"'s lane executed( \\(parity family: [^;\\n[:cntrl:]\\x{2028}\\x{2029}]*; [0-9]+ shard\\(s\\) on the PR side, [0-9]+ on main\\))?[ \\t]*(\\n|$)")] | all)
           and ([match("lane parity:[^\\n]*"; "g") | .string
                 | [match("\\(parity family:"; "g")] | length] | all(. <= 1))
           and (test("(^|\\n)[ \\t]*lane parity:[^\\n]*(NOT ESTABLISHED|FAILED|MISMATCH|DID NOT|NEVER ESTABLISHED)"; "i") | not)))'
jq_program='[ .comments[].body | select('"$CLAUSE_FILTER"') ] | length'

if [ -n "$BODY_FILE" ]; then
  # Offline mode: the body is the whole input, so wrap it as one comment. The
  # clause filter is the SAME string as the live path — one implementation of the
  # contract, so the two cannot drift apart (#1388 clause 6).
  body="$(cat "$BODY_FILE")"
  count="$(jq -n --arg b "$body" "[ \$b | select($CLAUSE_FILTER) ] | length" 2>/dev/null)"
else
  count="$("$GH" pr view "$PR" ${repo_args[@]+"${repo_args[@]}"} --json comments --jq "$jq_program" 2>/dev/null)"
fi

case "${count:-}" in
  ''|*[!0-9]*) printf 'verify-admin-merge-evidence: could not read the PR comments\n' >&2; exit 1 ;;
esac
if [ "$count" -gt 0 ]; then
  exit 0
fi
printf 'verify-admin-merge-evidence: no certifying evidence comment for head %s\n' "$HEAD" >&2
exit 1
