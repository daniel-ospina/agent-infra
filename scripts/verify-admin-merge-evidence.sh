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
# pipeline, so every clause must hold for the SAME comment. `contains` (not
# `test`) for the literal phrases — no regex escaping to get wrong.
jq_program='[ .comments[].body
  | select(contains("<!-- admin-merge-safety: '"$HEAD"' -->"))
  | select(contains("PR head: '"$HEAD"'"))
  | select(contains("main compared (union of "))
  | select(test("unique to this PR: 0([ \t\r\n]|$)"))
] | length'

if [ -n "$BODY_FILE" ]; then
  # Offline mode: the body is the whole input, so wrap it as one comment.
  body="$(cat "$BODY_FILE")"
  count="$(jq -n --arg b "$body" "[ \$b | select(contains(\"<!-- admin-merge-safety: $HEAD -->\")) | select(contains(\"PR head: $HEAD\")) | select(contains(\"main compared (union of \")) | select(test(\"unique to this PR: 0([ \t\r\n]|$)\")) ] | length" 2>/dev/null)"
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
