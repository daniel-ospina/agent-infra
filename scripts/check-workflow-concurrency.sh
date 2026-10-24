#!/usr/bin/env bash
# check-workflow-concurrency.sh — the SUPERSESSION invariant for workflow triggers (#2474).
#
# WHY THIS EXISTS
# ---------------
# The CI queue is a throughput ceiling for every lane, and the cheapest source of waste is a run
# for a head that has already been superseded: a push that starts a run which will finish after a
# newer push already exists. `cancel-in-progress` in a per-ref `concurrency` group is what removes
# it — and the way that block is written decides whether the optimisation is SAFE:
#
#   * keyed on the SHA, it never cancels anything (every head is its own group) — an inert gate;
#   * shared between two workflows, the two cancel EACH OTHER on the same PR;
#   * on `push` to the default branch, it cancels the base tree's own run — the tree every PR is
#     judged against — and no replacement run is created for that head;
#   * on a reusable workflow, it acts in the CALLEE's context, so two callers on one ref cancel
#     each other even though the callers each got it right.
#
# Every one of those is a silent, plausible-looking edit to a workflow file, which is exactly the
# class a text rule can hold. So the rules below are mechanical, and each one is pinned by a
# positive control in tests/actionlint/run.sh (a live file mutated to break the rule must RED).
#
# THE RULES
# ----------
#   R1  PR ENTRY POINT — a workflow triggered by `pull_request` or `pull_request_target` MUST
#       declare a workflow-level `concurrency:` with
#         - a `group` that carries the workflow's OWN identity — the file stem as a PREFIX
#           (`<stem>-…`), or `${{ github.workflow }}` — so two workflows on one PR cannot cancel
#           each other, AND a group no OTHER PR workflow also declares (a copied file that keeps
#           the old name is caught by the prefix; two files that reuse `github.workflow` are caught
#           by the duplicate check); and
#         - the REF — `${{ github.ref }}` or `${{ github.head_ref }}`, or
#           `${{ github.event.pull_request.number }}` for `pull_request_target` (there `github.ref`
#           is the BASE branch, so a ref key collapses every PR into one group); and
#         - `cancel-in-progress: true` — a superseded head is precisely what should be cancelled.
#   R2  PUSH — a workflow triggered by `push` MUST NOT cancel: either no `concurrency:` block, or
#       `cancel-in-progress: false`. A cancelled run on the default branch is a base-tree run that
#       measured nothing and will not be re-created for that head.
#   R3  REUSABLE — a workflow triggered ONLY by `workflow_call` MUST NOT declare `concurrency:`.
#       The caller owns supersession (it holds the ref and the PR), and a block here would apply
#       in the callee's context, letting two callers on the same ref cancel each other.
#   R4  THE #2474 EXEMPTION — `pipeline-compliance.yml` and `workflow-lock.yml` are the repo's two
#       GUARD workflows and are exempt from R1 while #2474 is open: `scripts/admin-merge.sh`'s
#       `NON_RED_CONC` reads a terminal `cancelled` leg as non-red and `guard_generation_complete`
#       accepts it as "the workflow ran", so supersession there trades a queue delay for a silent
#       loss of the verdict the guard exists to produce — on the repo's ONLY required status check
#       (#646). The exemption is FAIL-CLOSED IN BOTH DIRECTIONS: an exempt file that DOES declare
#       concurrency is RED (a stale exemption must not survive #2474), an exempt file that has LOST
#       its `#2474` rationale is RED (an exception copied without its reasoning is how a fail-open
#       becomes folklore), and an exempt file missing from the scan set is RED (a rename must not
#       silently re-arm R1's absence by disappearing the name instead).
#   R0  UNREADABLE IS NOT COMPLIANT — a workflow whose `on:` triggers this reader cannot resolve, or
#       that declares a JOB-level `concurrency:` (which GitHub honours and this check does not
#       model), is RED. Silence is not compliance: the dangerous direction for a check like this is
#       reporting green over a file it could not read.
#
# DECLARED OVER-BLOCKS (the cost of the rules above, stated rather than discovered)
# ------------------------------------------------------------------------------
#   * A workflow triggered by BOTH `push` and `pull_request` cannot satisfy R1 and R2 with ONE
#     block: R1 wants `cancel-in-progress: true`, R2 forbids it. Split the triggers into two
#     workflows — which is this repo's existing shape (`ci.yml` for PRs, `ci-main.yml` for main).
#     The message says so when it sees both triggers on one file.
#   * `push` with branch filters that provably exclude the default branch still trips R2. Modelling
#     branch filters means modelling YAML semantics, which is the creep this check refuses; the cost
#     is a visible, one-edit false red on a workflow that cannot actually cancel a main run.
#
# WHAT THIS DOES NOT COVER (stated, so a green run is not over-read)
# ------------------------------------------------------------------
#   * `workflow_run` / `workflow_dispatch`-only workflows (`admin-merge-detector.yml`). A run there
#     is keyed to a COMPLETED run of another workflow, not to a head, so "superseded" has no
#     meaning this guard could check; adding a group there would be a decision about that
#     workflow's semantics, not a concurrency invariant. It is classified, not overlooked.
#   * `templates/.github/workflows/` — the shipped copies consumers generate from. Same #2474
#     hazard for any consumer that adopts `scripts/admin-merge.sh`, and changing what consumers
#     generate is a wider blast radius than this check's remit; tracked with #2474.
#   * JOB-level `concurrency:` — refused (R0) rather than modelled. Hoist it to the workflow level.
#
# USAGE
#   scripts/check-workflow-concurrency.sh              # .github/workflows/*.yml + *.yaml (R4 armed)
#   scripts/check-workflow-concurrency.sh --table      # also print the per-file inventory (generated,
#                                                      # never hand-maintained — quote it, do not copy it)
#   scripts/check-workflow-concurrency.sh --root DIR   # repo mode against another tree (fixture tests)
#   scripts/check-workflow-concurrency.sh FILE...      # explicit files (fixtures; R4 is per-file only)
#
#   --table and --root may be given in either order, before or after the file list.
#
# EXIT
#   0  every rule held for every file scanned
#   1  at least one violation (each is printed, one per line, prefixed with the file)
#   2  usage / the scan set was empty (a check that reads nothing must not report PASS)

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# R4 — the closed exemption set, spelled out on purpose (not derived): a workflow must EARN an
# exemption by being named here WITH its issue, and that issue is why the file must still carry it.
EXEMPT_ISSUE="2474"
EXEMPT_FILES="pipeline-compliance.yml workflow-lock.yml"

TABLE=0
MODE="repo"
FILES=()

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help)
      # Print ONLY the header comment block: stop at the first non-comment line instead of guessing
      # a line range (a range leaked shell code into --help).
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
      exit 0 ;;
    --table)
      TABLE=1; shift ;;
    --root)
      [ -n "${2:-}" ] || { echo "usage: $0 [--table] [--root DIR] [FILE...]" >&2; exit 2; }
      ROOT="$(cd "$2" && pwd)" || { echo "❌ --root '$2' does not resolve to a directory" >&2; exit 2; }
      shift 2 ;;
    --)
      shift; while [ "$#" -gt 0 ]; do FILES+=("$1"); shift; done ;;
    -*)
      echo "usage: $0 [--table] [--root DIR] [FILE...] (see --help)" >&2; exit 2 ;;
    *)
      FILES+=("$1"); shift ;;
  esac
done

if [ "${#FILES[@]}" -gt 0 ]; then
  MODE="files"
else
  # BOTH extensions: a workflow added as `.yaml` is a workflow GitHub runs, so a `*.yml`-only glob is
  # a whole-file escape from every rule below. `-f` filters the unmatched glob bash leaves literal.
  for f in "$ROOT"/.github/workflows/*.yml "$ROOT"/.github/workflows/*.yaml; do
    [ -f "$f" ] && FILES+=("$f")
  done
fi

TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/wf-concurrency.XXXXXX")" || exit 2
TMP_GROUPS="$(mktemp "${TMPDIR:-/tmp}/wf-concurrency-groups.XXXXXX")" || exit 2
trap 'rm -f "$TMP_OUT" "$TMP_GROUPS"' EXIT

# The reader. One TAB-separated record per file:
#   <basename> \t <triggers> \t <hasconc> \t <group> \t <cancel> \t <joblevel> \t <on-parsed>
#
# Deliberately narrow, and therefore exact about what it can see: TOP-LEVEL keys and the two
# sections it needs. That is sound for valid workflow YAML (a `concurrency:` inside a block scalar
# is indented, and this reader anchors workflow-level keys on column 0) — and anything it CANNOT
# resolve is reported (on-parsed=0) rather than assumed compliant.
#
# Comments are stripped before parsing (a commented-out `concurrency:` must neither arm nor satisfy
# a rule); the strip only applies where the `#` follows whitespace, so a value is never truncated by
# a `#` inside it. CR is stripped too: a CRLF file is valid YAML, and a `false\r` that prints as
# `false` must not be refused as if it were a different value.
awk '
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function unq(s)  { if (s ~ /^".*"$/ ) return substr(s, 2, length(s) - 2)
                   if (substr(s, 1, 1) == SQ && substr(s, length(s), 1) == SQ) return substr(s, 2, length(s) - 2)
                   return s }
# addtrigger() — accept the shapes a trigger can be written in: a bare word, or a flow-list entry.
function addtrigger(v,   t) {
  t = unq(trim(v))
  if (t == "") return
  trig[t] = 1
}
# addflow() — `on: [push, pull_request]` and `on: {pull_request: {...}}`. A flow MAPPING carries its
# value after `:`, so each entry is cut at its first colon; braces are stripped first.
function addflow(v,   n, i, parts, t) {
  gsub(/^[\[{]/, "", v); gsub(/[\]}]$/, "", v)
  n = split(v, parts, /,[ \t]*/)
  for (i = 1; i <= n; i++) { t = parts[i]; sub(/:.*/, "", t); addtrigger(t) }
}
# flush() — print the record for the file just finished, then clear its state. Called at the first
# line of the NEXT file (so a previous record never carries content from the next file) and at EOF.
function flush(   tg, k, n) {
  if (fname == "") return
  n = 0; tg = ""
  for (k in trig) { n++; tg = tg (n > 1 ? " " : "") k }
  printf "%s\037%s\037%d\037%s\037%s\037%d\037%d\n", fname, tg, hasconc, group, cancel, joblevel, (n > 0 ? 1 : 0)
  delete trig; hasconc = 0; group = ""; cancel = ""; joblevel = 0; fname = ""; onindent = -1; cur = ""
}
BEGIN { cur = ""; SQ = sprintf("%c", 39); hasconc = 0; joblevel = 0; onindent = -1 }
{
  if (FNR == 1) {                         # a new file begins: close the previous record FIRST
    flush()
    fname = FILENAME; sub(/^.*\//, "", fname)
  }

  line = $0
  sub(/\r$/, "", line)
  sub(/^[ \t]*#.*$/, "", line)            # whole-line comment
  sub(/[ \t]+#[^#]*$/, "", line)          # trailing comment (only when preceded by whitespace)
  if (trim(line) == "") next

  if (line ~ /^[^ \t]/) {                 # a TOP-LEVEL key (column 0)
    cur = "?"
    if (match(line, /^"?[A-Za-z_][A-Za-z0-9_-]*"?:/)) {
      cur = substr(line, 1, RLENGTH - 1)
      gsub(/"/, "", cur)
    }
    onindent = -1
    if (cur == "on") {
      rest = trim(substr(line, index(line, ":") + 1))
      if (rest != "") addflow(rest)       # `on: push` / `on: [a, b]` / `on: {pull_request: {}}`
    }
    if (cur == "concurrency") { hasconc = 1 }
    next
  }

  # Indented content. Under `on:`: a trigger key at the FIRST child indent only (a nested
  # `branches:` under `pull_request:` is not a trigger).
  if (cur == "on") {
    if (match(line, /^[ \t]+/)) {
      ind = RLENGTH                     # the child indent (remember: match() resets RSTART/RLENGTH)
      key = substr(line, ind + 1)
      if (key ~ /^"?[A-Za-z_][A-Za-z0-9_-]*"?:/) {
        if (onindent < 0) { onindent = ind }
        if (ind == onindent) {           # a NESTED key (branches:, types:, inputs:) is not a trigger
          sub(/:.*$/, "", key); gsub(/"/, "", key)
          trig[key] = 1
        }
      }
    }
    next
  }

  # A JOB-level `concurrency:` (indented while we are NOT in the workflow-level section). GitHub
  # honours it and this check does not model it, so it is refused (R0) rather than ignored.
  if (line ~ /^[ \t]+"?concurrency"?[ \t]*:/) { joblevel = 1; next }

  if (cur == "concurrency") {
    t = trim(line)
    if (t ~ /^"?group"?[ \t]*:/) { group = unq(trim(substr(t, index(t, ":") + 1))) }
    else if (t ~ /^"?cancel-in-progress"?[ \t]*:/) { cancel = unq(trim(substr(t, index(t, ":") + 1))) }
  }
}
END { flush() }
' "${FILES[@]}" >"$TMP_OUT" 2>/dev/null
awk_rc=$?
if [ "$awk_rc" -ne 0 ]; then
  echo "❌ the workflow reader failed (rc=$awk_rc) — no verdict can be given" >&2
  exit 2
fi

errors=0
scanned=0
pr_seen=0
applied_exemptions=" "

fail() {
  echo "❌ $1"
  errors=$((errors + 1))
}

is_exempt() {
  case " $EXEMPT_FILES " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

has_trigger() { # has_trigger <triggers> <name>
  case " $1 " in
    *" $2 "*) return 0 ;;
  esac
  return 1
}

while IFS=$'\037' read -r fname triggers hasconc group cancel joblevel onparsed; do
  [ -n "${fname:-}" ] || continue
  scanned=$((scanned + 1))

  if [ "$TABLE" -eq 1 ]; then
    if [ "$hasconc" -eq 0 ]; then choice="no concurrency block"; else choice="group=$group cancel=$cancel"; fi
    [ "$joblevel" -eq 1 ] && choice="$choice  [JOB-LEVEL]"
    printf '  %-32s %-46s %s\n' "$fname" "${triggers:-<none>}" "$choice"
  fi

  # ---- R0: what could not be read is not compliant ----------------------------------------
  if [ "$onparsed" -eq 0 ]; then
    fail "$fname: this check could not read any trigger from the \`on:\` section — refusing to treat an unreadable workflow as non-PR. (A workflow is not run without \`on:\`; a shape this reader cannot resolve must be fixed or modelled.) [R0]"
    continue
  fi
  if [ "$joblevel" -eq 1 ]; then
    fail "$fname: declares a JOB-level \`concurrency:\`, which GitHub honours and this check does not model — hoist it to a workflow-level \`concurrency:\` (see --help) [R0]"
    continue
  fi

  is_pr=0
  if has_trigger "$triggers" pull_request || has_trigger "$triggers" pull_request_target; then
    is_pr=1
    pr_seen=$((pr_seen + 1))
  fi
  is_push=0
  has_trigger "$triggers" push && is_push=1
  is_reusable=0
  has_trigger "$triggers" workflow_call && is_reusable=1

  # ---- R2: a push-triggered workflow must never cancel a default-branch run ----------------
  if [ "$is_push" -eq 1 ]; then
    if [ "$hasconc" -eq 1 ]; then
      if [ "$cancel" = "true" ]; then
        if [ "$is_pr" -eq 1 ]; then
          fail "$fname: triggers BOTH \`push\` and a pull-request event, and cancels — one block cannot satisfy R1 (cancel on PR) and R2 (never cancel on push). Split the triggers into two workflows, as ci.yml (PR) and ci-main.yml (push) already are [R2]"
        else
          fail "$fname: triggers \`push\`, but \`concurrency.cancel-in-progress: true\` — a cancelled run on the default branch measured nothing and no replacement run is created for that head. Use \`cancel-in-progress: false\` (or drop the block) [R2]"
        fi
      elif [ "$cancel" != "false" ]; then
        fail "$fname: triggers \`push\` and declares \`cancel-in-progress: '${cancel:-<absent>}'\` — only the literal \`false\` is accepted on a push-triggered workflow [R2]"
      fi
    fi
  fi

  # ---- R1 / R4: PR entry points ------------------------------------------------------------
  if [ "$is_pr" -eq 1 ]; then
    if is_exempt "$fname"; then
      applied_exemptions="$applied_exemptions$fname "
      if [ "$hasconc" -eq 1 ]; then
        fail "$fname: is an EXEMPT GUARD (#$EXEMPT_ISSUE) but now declares \`concurrency:\` — if the rail has been fixed, remove it from EXEMPT_FILES in scripts/check-workflow-concurrency.sh in the same change; if not, this re-arms the #$EXEMPT_ISSUE fail-open [R4]"
      fi
      if [ -f "$ROOT/.github/workflows/$fname" ] && ! grep -q "#$EXEMPT_ISSUE" "$ROOT/.github/workflows/$fname"; then
        fail "$fname: is EXEMPT in this check but no longer carries its \`#$EXEMPT_ISSUE\` rationale — an exception without its reason is how a fail-open becomes folklore [R4]"
      fi
    else
      if [ "$hasconc" -eq 0 ]; then
        fail "$fname: triggers a pull request but declares NO workflow-level \`concurrency:\` block — every superseded head runs to completion and holds the queue [R1]"
      else
        stem="${fname%.*}"
        case "$group" in
          "$stem"-*|*'github.workflow'*) : ;;
          *) fail "$fname: \`concurrency.group\` ('$group') does not carry this workflow's own identity — expected a '$stem-' PREFIX or \`github.workflow\`; two workflows on one PR would cancel EACH OTHER [R1]" ;;
        esac
        printf '%s\t%s\n' "$group" "$fname" >>"$TMP_GROUPS"
        if has_trigger "$triggers" pull_request_target; then
          case "$group" in
            *'github.event.pull_request.number'*) : ;;
            *) fail "$fname: \`pull_request_target\` sets \`github.ref\` to the BASE branch, so a group keyed on '$group' collapses every PR into one — key it on \`github.event.pull_request.number\` [R1]" ;;
          esac
        else
          case "$group" in
            *'github.ref'*|*'github.head_ref'*) : ;;
            *) fail "$fname: \`concurrency.group\` ('$group') is not keyed on the PR — expected \`github.ref\` or \`github.head_ref\`. Keyed on a SHA it cancels nothing (each head is its own group) [R1]" ;;
          esac
        fi
        if [ "$cancel" != "true" ]; then
          fail "$fname: triggers a pull request but \`cancel-in-progress\` is '${cancel:-<absent>}' — a superseded head is exactly what should be cancelled [R1]"
        fi
      fi
    fi
  fi

  # ---- R3: a reusable workflow must not own concurrency ------------------------------------
  if [ "$is_reusable" -eq 1 ] && [ "$is_pr" -eq 0 ] && [ "$hasconc" -eq 1 ]; then
    fail "$fname: is a \`workflow_call\`-only (reusable) workflow and declares \`concurrency:\` — the block would apply in the CALLEE's context, so two callers on the same ref cancel each other; supersession belongs to the caller [R3]"
  fi
done <"$TMP_OUT"

# ---- two PR workflows must not share one group (they would cancel EACH OTHER) --------------
# Only reachable when both use `github.workflow` (identity per FILE NAME, not per file) or when one
# file was copied and kept the original group — the prefix rule above catches the copy, this catches
# the rest.
if [ -s "$TMP_GROUPS" ]; then
  dupes="$(awk -F'\t' '{ n[$1]++; f[$1] = f[$1] " " $2 } END { for (g in n) if (n[g] > 1) printf "%s\t%s\n", g, f[g] }' "$TMP_GROUPS")"
  if [ -n "$dupes" ]; then
    while IFS=$'\t' read -r dgroup dfiles; do
      [ -n "$dgroup" ] || continue
      fail "concurrency group '$dgroup' is declared by more than one PR workflow ($dfiles ) — they would cancel each other's runs on the same PR [R1]"
    done <<<"$dupes"
  fi
fi

# ---- anti-vacuity: a scan set that read nothing must not report PASS -----------------------
if [ "$scanned" -eq 0 ]; then
  echo "❌ no workflow files were scanned — refusing to report PASS over an empty scan set (<$MODE>)" >&2
  exit 2
fi
if [ "$MODE" = "repo" ] && [ "$pr_seen" -eq 0 ]; then
  echo "❌ no pull_request-triggered workflow was found in $ROOT/.github/workflows — R1 verified NOTHING (a broken glob or a renamed trigger must not read green)" >&2
  exit 2
fi
if [ "$MODE" = "repo" ]; then
  for exempt in $EXEMPT_FILES; do
    case "$applied_exemptions" in
      *" $exempt "*) : ;;
      *) fail "$exempt: named in EXEMPT_FILES but no such PR-triggered workflow was scanned — a renamed/deleted guard must not disappear from this check silently [R4]" ;;
    esac
  done
fi

if [ "$errors" -gt 0 ]; then
  echo ""
  echo "❌ $errors workflow-concurrency violation(s) — see \`scripts/check-workflow-concurrency.sh --help\` for the rules."
  exit 1
fi

echo "✅ workflow concurrency: $scanned file(s) scanned, $pr_seen PR entry point(s) checked (per-ref cancel), push workflows never cancel, reusable workflows own none"
exit 0
