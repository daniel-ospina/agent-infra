#!/usr/bin/env bash
# verify-admin-merge-evidence.sh — is this admin merge JUSTIFIED? (#984)
#
# The argv-level layer's decision rule. `scripts/gh-shim/gh` calls it when a
# RESOLVED argv is an admin merge. This is the CANONICAL definition of the
# certificate; the TypeScript gate (`extensions/review-enforcer/index.ts`,
# `evidenceBodyIsCertifying`) mirrors it IN-PROCESS, and the two must stay in step:
# a drift between two copies of this contract is exactly what #1429 was (the #3076
# class).
#
# HOW THE TWO ARE KEPT IN STEP, HONESTLY. `tests/admin-merge/run.sh` §35b binds
# THIS definition to the rail's OWN posted body (producer → this verifier) and
# mutates that body every way the zero could be faked. The TypeScript mirror is
# bound to the same contract by its own unit tests, NOT by that captured body — the
# admin-merge CI job runs bash only (no node), so the captured body cannot be fed to
# the TS gate there. The durable single-source fix (the TS gate delegating HERE) is
# a separate change and is recorded in #1388 clause 6, not done in this one.
# KNOWN ASYMMETRY — the two differ in strictness on two axes: `PR head:` is a
# literal containment here while the TS gate accepts a SHA PREFIX either way (TS
# looser), and the provenance line's lane is parsed and required by the TS gate
# while this one only requires the `main compared (union of ` prefix (TS stricter).
# Neither is uniformly stricter — but a merge is admitted only when BOTH certify
# (the tool-call gate runs first, the shim second), so an asymmetry cannot widen
# the conjunction.
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
#   … the residual is zero                ONE of the two shapes below
#
# THE RESIDUAL IS THE ANCHOR, NOT THE CLAUSE'S WORDING (#1429). The rail emits
# its zero as an `evidence_list` SECTION whose body is the entries of the final
# residual (BLOCKED ∪ UNATTRIBUTABLE). `evidence_list` renders one `- ` bullet
# per entry and falls back to its empty text ONLY when the list is empty, so the
# section's own rendering is the semantic zero — whatever the surrounding prose
# is worded. A body that lists residual entries is therefore refused even though
# the rail's clause reads `blocked by the decision: 0` (that clause is a literal
# `printf` the rail prints unconditionally, so on its own it would certify a
# nonzero residual beside it — a fail-open).
#
#   CURRENT (the rail, since bcbb7df / #3756):
#     … blocked by the decision: 0   AND the residual section renders no entries
#   LEGACY (evidence posted before the rename — kept valid, never produced again):
#     … unique to this PR: 0
#
# BOTH are accepted deliberately: widening the CONSUMER to the producer's real
# contract is the fix; narrowing the producer back to the obsolete literal would
# re-legalise the stronger, unsupported `unique to this PR` claim (#3756) and
# would invalidate every already-posted certificate.
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
# pipeline, so every clause must hold for the SAME comment. `contains` (not
# `test`) for the literal phrases — no regex escaping to get wrong.
# THE CERTIFICATE PREDICATE — defined ONCE, above both call paths, so the
# online (comment list) and offline (--body-file) forms cannot diverge.
#
# `residual_verdict` classifies the residual section(s); `certifies` is the ONLY
# place the zero is decided. The SECTION is the semantic anchor (#1429): the rail
# renders it through `evidence_list`, which prints one `- ` bullet per entry and
# falls back to its empty text ONLY when the list is empty — so "the section
# carries no entry" IS "the residual is zero", however the prose is worded, and
# the empty text may be REPHRASED without breaking the contract.
#
# HOW THE SECTION IS DELIMITED — and why the obvious read is unsafe. The body is
# taken from after the FIRST `final residual` summary to the FIRST `</details>`,
# and that region is REFUSED as `ambiguous` when either:
#   * a second `final residual` summary follows it, or
#   * the region before the close carries `<details` or `<!--`.
# The first rule is threat T2: a first-match read certifies an empty decoy placed
# before the real, bulleted section, so the evaluator must never guess WHICH
# section is the certificate. The second closes the T2 variant that a
# first-`</details>` read still allows — a NESTED `<details>…</details>`, or a
# close hidden inside an HTML comment (`<!-- </details> -->`), ends the region
# early, so a `- ` entry rendered AFTER it is never seen and the truncated prefix
# reads as the empty zero. Neither shape is anything the rail emits (its residual
# section is ONE `<details>` block whose body is the empty text or `- ` entries),
# so refusing both is the correct reading AND the fail-closed one. A MISSING close
# is `ambiguous` for the same reason: the rail always closes its block, so an
# unclosed one is not that block.
#
# WHY FIVE STATES AND NOT A BOOLEAN:
#   absent    — no `final residual` section at all. A LEGACY certificate (posted
#               before #3756) may omit it; the CURRENT clause must NOT accept it,
#               because absence of a measurement is not a measured zero.
#   empty     — exactly one section, stating something, rendering no entry. The
#               one shape that certifies beside the current clause.
#   entries   — a section renders at least one `- ` entry: a NON-ZERO residual.
#               Refused. `blocked by the decision: 0` is a literal `printf` the
#               rail prints unconditionally, so a clause-only predicate would
#               certify this — a fail-open.
#   ambiguous — more than one section, an unclosed one, or a section whose region
#               is broken by nesting/an HTML comment (above). Refused.
#   silent    — the section exists but carries no non-whitespace text. Refused; a
#               blank section measures nothing.
#
# The list-item test is LINE-ANCHORED (`(^|\n)[ \t]*([-*+]|[0-9]+\.)[ \t]`), not
# a bare search for `- `: the rail's empty text must stay free to contain a hyphen,
# and the TypeScript mirror uses the same form so the two cannot disagree on a body
# (an unanchored test refused a placeholder that merely contained `- `, false-blocking
# a legitimate zero-residual merge). It matches the OTHER markers GitHub renders as a
# list item (`* `, `+ `, `1. `) as well as the producer's `- `: the producer emits only
# `- `, so the extra markers cost nothing and close the "the section renders an entry
# but the gate reads it as empty" surface.
#
# THE CLAUSE IS THE COUNTS LINE, NOT A FREE-FLOATING PHRASE. Each accepted zero is
# matched as the TAIL of `PR failing: <n> | main failing: <m> | `, exactly as the
# TypeScript mirror does. Matching the phrase alone (as an earlier cut did) let a body
# with NO counts at all certify — the vacuity the docstring above says this closes.
#
# ENGINE PARITY IS PART OF THE CONTRACT. This program is shipped to `gh --jq`
# (gojq, whose regex engine is Go/RE2) AND run by system `jq` (Oniguruma) in
# `--body-file` mode, and mirrored in TypeScript. `\s`, `\S` and `[[:space:]]`
# DISAGREE between those engines on invisible spaces — Oniguruma's `\s` matches
# U+00A0, U+2000…, U+0085; RE2's is ASCII-only — so a predicate written with them
# CERTIFIES in production what the test suite REFUSES (a gate whose proven
# contract is not the shipped one). Every class here is therefore written out in
# ASCII — `[ \t\r\n]` for the clause terminator and `[!-~]` (printable ASCII)
# for "the section states something" — never `\s`, `\S`, or a POSIX class.
# `[!-~]` is the STRICTER choice: a section carrying only an invisible space
# (U+00A0 and friends) is `silent` in EVERY engine, so parity costs no refusal.
# §35b asserts this file's program carries none of them.
#
# BOUNDED, AND OFFSET-FREE ON PURPOSE. The only scans are one `capture` (which
# hands back the text after the first summary via its `(?<rest>…)` group), then
# `test`/`split` on that text — no global match, no loop, and NO OFFSET
# ARITHMETIC, so a hostile 64 KB comment cannot buy a stall by packing itself
# with tags or with `final residual` summaries. Offsets are avoided deliberately:
# in this jq build `index` returns a BYTE offset while string slicing is by
# CODEPOINT, so `$s[0:($s|index("x"))]` silently overshoots on any multibyte body
# — and the rail's empty text carries an em dash, so that is the NORMAL case, not
# a corner. `match.offset` is codepoint-consistent with slicing, but `capture` +
# `split` makes the point moot in every engine.
CERT_JQ='
def residual_verdict:
  ("(?s)<summary>[^<]*final residual[^<]*</summary>(?<rest>.*)") as $re
  | ([capture($re)] | .[0]) as $c
  | if $c == null then "absent"
    else
      ($c.rest) as $after
      | if ($after | test("<summary>[^<]*final residual[^<]*</summary>")) then "ambiguous"
        elif ($after | test("</details>")) then
          ($after | split("</details>") | .[0]) as $r
          | if ($r | test("<details|<!--")) then "ambiguous"
            elif (($r | test("[!-~]")) | not) then "silent"
            elif ($r | test("(^|\\n)[ \\t]*([-*+]|[0-9]+\\.)[ \\t]")) then "entries"
            else "empty"
            end
        else "ambiguous"
        end
    end;
def certifies:
  (residual_verdict) as $rv
  | (test("PR failing: [0-9]+[ \t\r\n]*\\|[ \t\r\n]*main failing: [0-9]+[ \t\r\n]*\\|[ \t\r\n]*unique to this PR: 0([ \t\r\n]|$)") and ($rv == "absent" or $rv == "empty"))
    or (test("PR failing: [0-9]+[ \t\r\n]*\\|[ \t\r\n]*main failing: [0-9]+[ \t\r\n]*\\|[ \t\r\n]*blocked by the decision: 0([ \t\r\n]|$)") and $rv == "empty");
'

jq_program="$CERT_JQ
[ .comments[].body
  | select(contains(\"<!-- admin-merge-safety: $HEAD -->\"))
  | select(contains(\"PR head: $HEAD\"))
  | select(contains(\"main compared (union of \"))
  | select(certifies)
] | length"

if [ -n "$BODY_FILE" ]; then
  # Offline mode: the body is the whole input, so wrap it as one comment.
  body="$(cat "$BODY_FILE")"
  count="$(jq -n --arg b "$body" "$CERT_JQ
[ \$b | select(contains(\"<!-- admin-merge-safety: $HEAD -->\")) | select(contains(\"PR head: $HEAD\")) | select(contains(\"main compared (union of \")) | select(certifies) ] | length" 2>/dev/null)"
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
