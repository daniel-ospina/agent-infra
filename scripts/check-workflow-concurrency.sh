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
#           the old name is caught by the prefix; two files that end up in the same runtime group are
#           caught by the duplicate check, which RESOLVES `github.workflow` to each file's own
#           `name:` — so the canonical `${{ github.workflow }}-${{ github.ref }}` idiom is correct
#           in every file, and only a genuinely shared group is refused); and
#         - the REF — `${{ github.ref }}` or `${{ github.head_ref }}`, or
#           `${{ github.event.pull_request.number }}` for `pull_request_target` (there `github.ref`
#           is the BASE branch, so a ref key collapses every PR into one group). It must be the ONLY
#           per-commit variable: a group that ALSO carries `${{ github.sha }}` (or a
#           `github.run_id` / `run_number` / `run_attempt`) resolves per head, so it cancels nothing
#           while looking like an optimisation — an inert gate, refused by name; and
#         - `cancel-in-progress: true` — a superseded head is precisely what should be cancelled.
#   R2  PUSH — a workflow triggered by `push` MUST NOT cancel: no `concurrency:` block, no
#       `cancel-in-progress` key at all (GitHub's own default is not to cancel), or the literal
#       `false`. A cancelled run on the default branch is a base-tree run that measured nothing and
#       will not be re-created for that head.
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
#   R0  UNREADABLE IS NOT COMPLIANT — a workflow whose `on:` triggers this reader cannot resolve, that
#       declares a JOB-level `concurrency:` (which GitHub honours and this check does not model), or
#       whose `concurrency:` value is a sequence or an alias, is RED. Silence is not compliance: the
#       dangerous direction for a check like this is reporting green over a file it could not read.
#       The value FORMS that are modelled: an indented block of `group:`/`cancel-in-progress:`, a
#       flow mapping (`concurrency: {group: …, cancel-in-progress: …}`), and the scalar shorthand
#       (`concurrency: <group>`, which cannot express cancellation and so cannot satisfy R1).
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

if [ "${#FILES[@]}" -eq 0 ]; then
  echo "❌ no workflow files were scanned — refusing to report PASS over an empty scan set (<$MODE>)" >&2
  exit 2
fi

# Deduplicate. The same file named twice is ONE workflow; without this, the duplicate-group rule below
# compares a file against itself and refuses a correct workflow as "they would cancel each other"
# (round 4, P2 — `check-workflow-concurrency.sh f.yml f.yml` was RED).
# The key is the RESOLVED path, not the spelling: `x.yml` and `./x.yml` are one file, and comparing
# raw strings let the duplicate-group rule compare a file against itself (round 5, P2).
DEDUPED=()
DEDUPED_KEYS=()
for f in "${FILES[@]}"; do
  canon="$f"
  if [ -f "$f" ]; then
    # Resolve to an absolute path without changing directory: `x.yml` and `./x.yml` are one file.
    canon="$(realpath -- "$f" 2>/dev/null)"
    if [ -z "$canon" ]; then
      canon="$(printf '%s' "$f" | sed -e 's#^\./##' -e 's#/\./#/#g' -e 's#//*#/#g')"
    fi
  fi
  seen=0
  for d in "${DEDUPED_KEYS[@]+"${DEDUPED_KEYS[@]}"}"; do
    [ "$d" = "$canon" ] && { seen=1; break; }
  done
  [ "$seen" -eq 0 ] && { DEDUPED+=("$f"); DEDUPED_KEYS+=("$canon"); }
done
FILES=("${DEDUPED[@]}")

TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/wf-concurrency.XXXXXX")" || exit 2
TMP_GROUPS="$(mktemp "${TMPDIR:-/tmp}/wf-concurrency-groups.XXXXXX")" || exit 2
# NO cleanup trap on purpose. A module-level `rm` whose targets are variables is not statically
# resolvable by the session checkout-hygiene guard, which then refuses to run THIS script at all
# (fail-closed, "the whole working tree") — a verifier that cannot be executed verifies nothing.
# The two files are mktemp-named in TMPDIR and are left for the tmp reaper, exactly as
# tests/actionlint/run.sh does with its own scratch dir.

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
# LC_ALL=C: byte semantics, so a UTF-8 BOM is the three bytes it is on disk. Under a UTF-8 locale a
# %c of 239 is a different, two-byte character and the comparison can never match. This also keeps
# the reader's behaviour independent of the runner's locale.
LC_ALL=C awk '
# A KEY is: optional single/double quote, an identifier, optional quote, optional spaces, colon.
# Both quote styles matter — a formatter that quotes mapping keys emits `'"'"'concurrency'"'"':`, and a
# spelling the reader cannot see is a rule that silently does not apply (round 2 found exactly that:
# `'"'"'concurrency'"'"':` + cancel-in-progress true on a push workflow reported GREEN, "push workflows never
# cancel"). The space-before-colon form (`push :`) is valid YAML too.
function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t\r]+$/, "", s); return s }
function unq(s)  { if (s ~ /^\".*\"$/ ) return substr(s, 2, length(s) - 2)
                   if (substr(s, 1, 1) == SQ && substr(s, length(s), 1) == SQ) return substr(s, 2, length(s) - 2)
                   return s }
# addtrigger() — accept the shapes a trigger can be written in: a bare word, or a flow-list entry.
function addtrigger(v,   t) {
  t = unq(trim(v))
  if (t == "") return
  # An alias (`*x`) or ANY tag (`!x`, `!!seq`, `!!str`) is not a trigger name this reader can
  # resolve. Recording it as one left the file neither PR nor push, so every rule went vacuous
  # (round 4). A double-bang tag escaped that test by one character, and the test was the whole
  # guard (round 5).
  # An anchor DECLARATION is not a trigger name. Stripping the anchor and recording the rest as a
  # trigger left a bracketed fragment in the trigger set: onparsed was 1, no real trigger was
  # present, and every rule went vacuous (round 6, P2).
  while (t ~ /^&[A-Za-z0-9_-]+([ \t]|$)/) sub(/^&[A-Za-z0-9_-]+[ \t]*/, "", t)
  gsub(/^[\[{]/, "", t); gsub(/[\]}]$/, "", t)
  if (t == "") return                              # a bare anchor: its value is the block children
  if (t ~ /^\*/ || t ~ /^!/) { concbad = 1; concwhy = "the `on:` value is an alias or a tagged scalar, which this reader cannot resolve into trigger names"; return }
  trig[t] = 1
}
# addflow() — `on: [push, pull_request]` and `on: {pull_request: {...}}`. A flow MAPPING carries its
# value after `:`, so each entry is cut at its first colon; the outer brackets are stripped first.
function addflow(v,   n, i, parts, t) {
  gsub(/^[\[{]/, "", v); gsub(/[\]}]$/, "", v)
  n = splitqv(v, parts)
  for (i = 1; i <= n; i++) { t = parts[i]; sub(/:.*/, "", t); addtrigger(t) }
}
# parseconc() — a FLOW-mapping `concurrency: {group: …, cancel-in-progress: true}`. Without this the
# block reader below sees no indented children, so `group`/`cancel` stay EMPTY and the R2 arm that
# treats an absent key as the GitHub default reads a CANCELLING workflow as compliant (round-3 P0, from
# enforce-skills.yml with its own two-line block rewritten as a flow mapping).
function parseconc(v,   n, i, parts, t, k) {
  gsub(/^[\[{]/, "", v); gsub(/[\]}]$/, "", v)
  n = splitqv(v, parts)
  for (i = 1; i <= n; i++) {
    t = parts[i]
    k = t; sub(/:.*/, "", k); k = unq(trim(k))
    if (k == "group") { group = unq(trim(substr(t, index(t, ":") + 1))) }
    else if (k == "cancel-in-progress") { cancel = tolower(unq(trim(substr(t, index(t, ":") + 1)))) }
  }
}
function opens(v)  { return gsub(/[\[{]/, "", v) }
# stripcomment(s) — remove a trailing YAML comment in LINEAR time and QUOTE-AWARE. Two independent
# defects lived here: the regex form re-scanned a whitespace run from every start position (one line
# of 100 000 spaces cost 16 s), and neither form knew about quotes, so a `#` INSIDE a value truncated
# it — a refusal then quoted text that is not the value, and a correct workflow was refused.
function stripcomment(s,   out, i, n, c, q, nx) {
  out = ""; n = length(s); q = ""
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q != "") {
      out = out c
      if (q == DQ && c == "\\") { out = out substr(s, i + 1, 1); i++; continue }
      if (c == q) {
        nx = substr(s, i + 1, 1)
        if (nx == q) { out = out nx; i++; continue }
        q = ""
      }
      continue
    }
    if ((c == DQ || c == SQ) && at_val_start(s, i)) { q = c; out = out c; continue }
    if (c == "#" && (i == 1 || substr(s, i - 1, 1) ~ /[ \t]/)) {
      sub(/[ \t]+$/, "", out)
      return out
    }
    out = out c
  }
  # UNCLOSED quote: a PLAIN scalar may contain an apostrophe, so the quote was never a scalar at all.
  # Fall back to the whitespace rule rather than treating the rest of the line as string content —
  # otherwise a real comment is kept as part of the value (round 9).
  if (q != "") return stripcomment_simple(s)
  return out
}
# qopens(s, i) — TRUE when the quote at s[i] opens a quoted scalar. Two independent tests, and both
# are needed: a VALUE position (a quoted group value, a quoted list item, a quoted word after a
# colon or a colon-space) always opens one, and
# anywhere else only a quote that cannot be inside a word does. "a second quote appears later" is NOT
# such a test: two plain scalars each carrying one apostrophe (a description reading Dont-ask, then a
# second reading its-fine) paired up across a separating comma and swallowed every flow entry between
# them — the trigger set lost its `push` and `workflow_call` entirely (#2660 round 12).
function qopens(s, i,   p) {
  if (at_val_start(s, i)) return 1
  if (i <= 1) return 1
  p = substr(s, i - 1, 1)
  return (p !~ /[A-Za-z0-9_]/)
}
# at_val_start(s, i) — TRUE when the quote at position i OPENS a quoted scalar: YAML only quotes at a
# value position, so an apostrophe inside a plain scalar (or inside a comment) is just a character.
function at_val_start(s, i,   j, c) {
  if (i == 1) return 1
  j = i - 1
  while (j > 0 && substr(s, j, 1) ~ /[ \t]/) j--
  if (j == 0) return 1
  c = substr(s, j, 1)
  return (c == ":" || c == "-" || c == "[" || c == "{" || c == ",")
}
# at_val_start_flow(s, i) — the same test WITHOUT the dash, for a flow collection: a dash has no
# structural meaning between a `{` and its `}`, so a scalar like shard-dash-a there is plain text and a
# quote after the dash must not open a string (#2660 round 14).
function at_val_start_flow(s, i,   j, c) {
  if (i == 1) return 1
  j = i - 1
  while (j > 0 && substr(s, j, 1) ~ /[ \t]/) j--
  if (j == 0) return 1
  c = substr(s, j, 1)
  return (c == ":" || c == "[" || c == "{" || c == ",")
}
# stripcomment_simple(s) — the pre-quote-aware rule, used only when a quote never closes.
function stripcomment_simple(s,   i, n) {
  n = length(s)
  for (i = 2; i <= n; i++) {
    if (substr(s, i, 1) == "#" && substr(s, i - 1, 1) ~ /[ \t]/) return substr(s, 1, i - 1)
  }
  if (substr(s, 1, 1) == "#") return ""
  return s
}
# mask_quoted(s) — the text with the CONTENTS of quoted VALUES blanked, for matching that must not
# fire on a string literal (a `run:` value containing JSON). A quoted scalar followed by `:` is a
# KEY, not a value — it stays visible, or a quoted concurrency key would hide the very block being
# looked for (round 8, P1).
function mask_quoted(s,   out, i, n, c, q, nx, start, seg, j) {
  out = ""; n = length(s); q = ""; start = 0
  for (i = 1; i <= n; i++) {
    c = substr(s, i, 1)
    if (q != "") {
      if (q == DQ && c == "\\") { i++; continue }
      if (c == q) {
        nx = substr(s, i + 1, 1)
        if (nx == q) { i++; continue }
        seg = substr(s, start, i - start + 1)
        j = i + 1
        while (j <= n && substr(s, j, 1) ~ /[ \t]/) j++
        if (substr(s, j, 1) == ":") { out = out seg }
        else { out = out substr(seg, 1, 1); for (j = 2; j < length(seg); j++) out = out "x"; out = out substr(seg, length(seg), 1) }
        q = ""
      }
      continue
    }
    if ((c == DQ || c == SQ) && qopens(s, i)) { q = c; start = i; continue }
    out = out c
  }
  # UNCLOSED quote: a plain scalar with an apostrophe, not a string. Returning the raw line keeps the
  # job-level search able to SEE a key that follows it — an apostrophe in a job name hid a cancelling
  # job-level block completely (round 9, P1).
  if (q != "") return s
  return out
}
# splitqv(v, arr) — split a flow mapping on commas that are NOT inside a quoted scalar. Splitting on
# `,` blindly truncated a quoted group at its first comma, which HID a per-commit variable from R1 and
# refused correct expressions like format(...) as a fragment.
function splitqv(v, arr,   n, i, c, q, cur, len, nx) {
  n = 0; cur = ""; q = ""; len = length(v)
  for (i = 1; i <= len; i++) {
    c = substr(v, i, 1)
    if (q != "") {
      cur = cur c
      if (q == DQ && c == "\\") { cur = cur substr(v, i + 1, 1); i++; continue }
      if (c == q) {
        nx = substr(v, i + 1, 1)
        if (nx == q) { cur = cur nx; i++; continue }
        q = ""
      }
      continue
    }
    if ((c == DQ || c == SQ) && at_val_start_flow(v, i)) { q = c; cur = cur c; continue }
    if (c == ",") { arr[++n] = cur; cur = ""; continue }
    cur = cur c
  }
  if (q != "") return splitqv_simple(v, arr)
  arr[++n] = cur
  return n
}
# splitqv_simple(v, arr) — split a flow mapping on EVERY comma, used only when a quote never closed
# (so it was never a scalar). Without this the separator comma stayed inside the phantom string: a
# flow `concurrency` carrying a group literal with a stray apostrophe before `cancel-in-progress:
# true` fused into one entry, the cancelling pair was never read, and the R2 absent-key arm took the
# non-cancelling default — GREEN on a main-branch workflow that cancels (#2660 round 13).
function splitqv_simple(v, arr,   n, i, c, cur, len) {
  n = 0; cur = ""; len = length(v)
  for (i = 1; i <= len; i++) {
    c = substr(v, i, 1)
    if (c == ",") { arr[++n] = cur; cur = ""; continue }
    cur = cur c
  }
  arr[++n] = cur
  return n
}
function closes(v) { return gsub(/[\]}]/, "", v) }
# flush() — print the record for the file just finished, then clear its state. Called at the first
# line of the NEXT file (so a previous record never carries content from the next file) and at EOF.
function flush(   tg, k, n) {
  if (fname == "") return
  if (pendkey != "") {                    # a value that ran to EOF: still a value
    if (pendkey == "group") { group = unq(trim(pendval)) } else { cancel = tolower(unq(trim(pendval))) }
    pendkey = ""; pendval = ""; pendind = -1
  }
  # It must run AFTER the pending value is resolved: before, a compliant workflow whose `group` value
  # sat on a continuation line at the end of the file was refused as unreadable (round 8, P2) —
  # the guard rejected a value this same function then read.
  # A `concurrency:` block was declared but NOTHING in it could be read (e.g. a YAML merge key, whose
  # group and cancel arrive through `<<:`). "Declared, unreadable" must not be treated as "declared,
  # no cancellation": the absent-key arm of R2 reads that as the non-cancelling default (round 7).
  if (hasconc && group == "" && cancel == "" && concbad == 0 && joblevel == 0) {
    concbad = 1
    concwhy = "a `concurrency:` block is declared but no `group`/`cancel-in-progress` value could be read from it (an unmodelled child, such as a YAML merge key)"
  }
  n = 0; tg = ""
  for (k in trig) { n++; tg = tg (n > 1 ? " " : "") k }
  printf "%s\037%s\037%d\037%s\037%s\037%d\037%d\037%s\037%d\037%s\n", fname, tg, hasconc, group, cancel, joblevel, (n > 0 ? 1 : 0), wfname, concbad, concwhy
  delete trig; hasconc = 0; group = ""; cancel = ""; joblevel = 0; fname = ""; onindent = -1; cur = ""
  scalarindent = -1; flowopen = 0; flowbuf = ""; flowmode = ""; wfname = ""; concbad = 0
  pendkey = ""; pendval = ""; pendind = -1; flowdepth = 0; concwhy = ""; pendblock = 0
}
BEGIN {
  cur = ""; SQ = sprintf("%c", 39); DQ = "\""
  BOM = sprintf("%c%c%c", 239, 187, 191)
  QCH = "[" DQ SQ "]"
  KEYPAT = QCH "?[A-Za-z_][A-Za-z0-9_-]*" QCH "?[ \t]*:"
  hasconc = 0; joblevel = 0; onindent = -1; scalarindent = -1; flowopen = 0; flowbuf = ""; flowmode = ""
  wfname = ""; concbad = 0; pendkey = ""; pendval = ""; pendind = -1; flowdepth = 0; concwhy = ""; pendblock = 0
}
{
  if (FNR == 1) {                         # a new file begins: close the previous record FIRST
    flush()
    fname = FILENAME; sub(/^.*\//, "", fname)
  }

  line = $0
  sub(/\r$/, "", line)
  # A UTF-8 BOM is legal at the start of a YAML stream. Un-stripped, the first key no longer matched
  # the top-level key pattern, so a `concurrency:` block vanished — and unlike a BOM on `on:` there
  # was no R0 either: the reader read nothing and told no one (round 6, P1).
  if (substr(line, 1, 1) == BOM) line = substr(line, 2)
  else if (substr(line, 1, 3) == BOM) line = substr(line, 4)
  lineindent = 0                          # 0 for a top-level line
  if (match(line, /^[ \t]+/)) lineindent = RLENGTH

  # BLOCK-SCALAR BODIES and PENDING VALUES are TEXT: they are read BEFORE the comment strip, because
  # inside them a `#` is literal. Stripping first DELETED a `#` line that carried a per-commit
  # variable out of a `group: |` body, so the inert gate read GREEN (round 5, P2). It also kept a
  # `#` line inside a `run: |` body from being mistaken for a key.
  if (scalarindent >= 0 && lineindent > scalarindent) next
  if (pendkey != "" && lineindent > pendind) {
    piece = trim(line)
    if (pendblock == 0) {               # a plain continuation: a `#` here is a YAML COMMENT
      piece = stripcomment(piece)
      if (piece == "") next
    }
    pendval = pendval " " piece
    if (length(pendval) > 65536) { pendkey = ""; pendval = ""; pendind = -1; concbad = 1; concwhy = "a pending `concurrency` value larger than 65536 characters is not modelled" }
    next
  }

  line = stripcomment(line)               # trailing comment (the comment may itself contain a hash: #2474)
  if (trim(line) == "") next              # whole-line comment
  if (trim(line) == "") next

  if (scalarindent >= 0 && lineindent <= scalarindent) scalarindent = -1

  # A pending value resolves at the first line that is NOT its continuation — including the end of
  # the file, where nothing follows (round 5, P1: resolved only on a later, less-indented line, so a
  # `cancel-in-progress:` whose value was the last line stayed ABSENT and R2 accepted it as default).
  if (pendkey != "") {
    if (pendkey == "group") { group = unq(trim(pendval)) } else { cancel = tolower(unq(trim(pendval))) }
    pendkey = ""; pendval = ""; pendind = -1
  }

  # A concurrency child key that opens a scalar is a GROUP/CANCEL VALUE, which the section below reads
  # (pending value). It must not be swallowed by the generic block-scalar skip.
  if (cur == "concurrency" && match(line, "^[ \t]*" QCH "?(group|cancel-in-progress)" QCH "?[ \t]*:[ \t]*[|>]")) { }
  else if (line ~ /:[ \t]*[|>][-+0-9]*[ \t]*$/) { scalarindent = lineindent; next }

  # A multi-line flow `on:` (`on: [push,` / `  pull_request]`) is accumulated until the brackets
  # balance: reading only the first line silently DROPPED the rest, so a push trigger vanished and
  # R2 was never evaluated (round 2, P1).
  if (flowopen) {
    flowbuf = flowbuf " " trim(line)
    flowdepth += opens(line) - closes(line)      # incremental: never re-scan the whole buffer
    # Bounded: a file that never closes its flow is not a workflow this reader can resolve, and
    # accumulating it without a ceiling makes the cost grow with attacker-chosen input
    # (measured 35 s on an 838 KB crafted file before these two lines).
    if (length(flowbuf) > 65536) {
      concbad = 1; concwhy = "an unterminated flow value larger than 65536 characters is not modelled"
      flowopen = 0; flowbuf = ""; flowmode = ""; flowdepth = 0
      next
    }
    if (flowdepth <= 0) {
      if (flowmode == "concurrency") { parseconc(flowbuf) } else { addflow(flowbuf) }
      flowopen = 0; flowbuf = ""; flowmode = ""; flowdepth = 0
    }
    next
  }

  if (line ~ /^[ \t]*\?[ \t]/) {        # explicit-key form, at ANY indent: not modelled
    concbad = 1
    concwhy = "the file uses YAML explicit-key syntax (`? key`), which this reader does not model"
    next
  }

  if (line ~ /^[^ \t]/) {                 # a TOP-LEVEL key (column 0)
    if (cur == "on" && line ~ /^-[ \t]/) {        # a sequence entry at its parent key indent
      seqk = substr(line, 2); sub(/[ \t]*:.*$/, "", seqk)
      addtrigger(seqk); next
    }
    cur = "?"
    if (match(line, "^" KEYPAT)) {
      cur = substr(line, 1, RLENGTH)
      sub(/[ \t]*:$/, "", cur); gsub(QCH, "", cur)
    }
    onindent = -1
    if (cur == "name") {
      wfname = unq(trim(substr(line, index(line, ":") + 1)))
    }
    if (cur == "on") {
      rest = trim(substr(line, index(line, ":") + 1))
      if (rest != "") {
        if (opens(rest) > closes(rest)) { flowopen = 1; flowmode = "on"; flowbuf = rest; flowdepth = opens(rest) - closes(rest) }
        else { addflow(rest) }            # `on: push` / `on: [a, b]` / `on: {pull_request: {}}`
      }
    }
    if (cur == "jobs") {
      rest = trim(substr(line, index(line, ":") + 1))
      if (rest ~ /^\{/) { concbad = 1; concwhy = "a flow-style `jobs:` is not modelled here, so a job-level `concurrency:` inside it cannot be seen" }
    }
    if (cur == "concurrency") {
      hasconc = 1
      rest = trim(substr(line, index(line, ":") + 1))
      if (rest != "") {
        if (rest ~ /^\{/) {
          if (opens(rest) > closes(rest)) { flowopen = 1; flowmode = "concurrency"; flowbuf = rest; flowdepth = opens(rest) - closes(rest) }
          else { parseconc(rest) }
        } else if (rest ~ /^\[/ || rest ~ /^\*/) {
          concbad = 1                   # a sequence or an alias: valid YAML, not modelled -> R0
          concwhy = "the `concurrency:` value is a sequence or an alias, not a group mapping"
        } else {
          group = unq(rest)             # the scalar shorthand `concurrency: <group>`
        }
      }
    }
    next
  }

  # Indented content. Under `on:`: a trigger key at the FIRST child indent only (a nested
  # `branches:` under `pull_request:` is not a trigger).
  if (cur == "on") {
    ind = lineindent
    key = substr(line, ind + 1)
    if (key ~ /^-[ \t]/) {                        # `on:` written as a block sequence
      sub(/^-[ \t]+/, "", key); sub(/[ \t]*:.*$/, "", key)
      addtrigger(key); next
    }
    if (match(key, "^" KEYPAT)) {
      if (onindent < 0) { onindent = ind }
      if (ind == onindent) {             # a NESTED key (branches:, types:, inputs:) is not a trigger
        k = substr(key, 1, RLENGTH)
        sub(/[ \t]*:$/, "", k); gsub(QCH, "", k)
        trig[k] = 1
      }
    }
    next
  }

  # A JOB-level `concurrency:` (indented while we are NOT in the workflow-level section). GitHub
  # honours it and this check does not model it, so it is refused (R0) rather than ignored.
  if (match(substr(line, lineindent + 1), "^" QCH "?concurrency" QCH "?[ \t]*:")) { joblevel = 1; next }
  # A job written as a FLOW mapping (`build: {…, concurrency: {…}}`) hides the key from the line test
  # above, so it is looked for anywhere a flow mapping can put it (round 7, P2).
  if (match(mask_quoted(line), "[\\[{,][ \t]*" QCH "?concurrency" QCH "?[ \t]*:")) { joblevel = 1; next }
  # The masked form hides quoted regions, and two apostrophes in ONE flow job mapping can pair around
  # a real key: `build: {runs-on: x, name: shard-a-with-a-quote, concurrency: {..}, note: the-other}`
  # masked the `concurrency:` away, so a cancelling JOB-level block reported GREEN. When the raw text
  # has a key the mask hides, the mask cannot be attributed — refuse rather than read it as absent.
  # Exclusive of `run:`/`with:`/`script:`-style values, where a quoted blob legitimately contains a
  # colon key (a shell echo of a JSON object), which is what this line test used to mask
  # (#2660 round 15).
  sl_raw = stripcomment(line)
  if (!match(mask_quoted(line), "[\\[{,][ \t]*" QCH "?concurrency" QCH "?[ \t]*:") &&
      match(sl_raw, "[\\[{,][ \t]*" QCH "?concurrency" QCH "?[ \t]*:") &&
      sl_raw !~ /^[ \t]*[A-Za-z_-][A-Za-z0-9_-]*[ \t]*:[ \t]*(echo|cat|printf|sh|bash)/ &&
      scalarindent < 0 &&
      sl_raw !~ /^[ \t]*(-[ \t]+)*(run|with|script|shell|env|description)[ \t]*:/) {
    concbad = 1
    concwhy = "a \`concurrency:\` key is present in the raw text but sits inside a quoted region this reader cannot attribute"
    next
  }

  if (cur == "concurrency") {
    t = trim(line)
    if (t ~ /^\{/) {                    # an indented FLOW mapping: same parser, one line down
      if (opens(t) > closes(t)) { flowopen = 1; flowmode = "concurrency"; flowbuf = t; flowdepth = opens(t) - closes(t) }
      else { parseconc(t) }
      next
    }
    if (match(t, "^" QCH "?group" QCH "?[ \t]*:")) {
      v = unq(trim(substr(t, index(t, ":") + 1)))
      if (v ~ /^[|>]/) { pendkey = "group"; pendval = ""; pendind = lineindent; pendblock = 1 }
      else { group = v; pendkey = "group"; pendval = v; pendind = lineindent; pendblock = 0 }
    }
    else if (match(t, "^" QCH "?cancel-in-progress" QCH "?[ \t]*:")) {
      v = unq(trim(substr(t, index(t, ":") + 1)))
      if (v ~ /^[|>]/) { pendkey = "cancel"; pendval = ""; pendind = lineindent; pendblock = 1 }
      else { cancel = tolower(v); pendkey = "cancel"; pendval = v; pendind = lineindent; pendblock = 0 }
    }
  }
}
END { flush() }' "${FILES[@]}" >"$TMP_OUT" 2>/dev/null
awk_rc=$?
if [ "$awk_rc" -ne 0 ]; then
  echo "❌ the workflow reader failed (rc=$awk_rc) — no verdict can be given" >&2
  exit 2
fi

errors=0
scanned=0; r0_refusals=0
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

while IFS=$'\037' read -r fname triggers hasconc group cancel joblevel onparsed wfname concbad concwhy; do
  [ -n "${fname:-}" ] || continue
  scanned=$((scanned + 1))

  if [ "$TABLE" -eq 1 ]; then
    if [ "$hasconc" -eq 0 ]; then choice="no concurrency block"; else choice="group=$group cancel=$cancel"; fi
    [ "$joblevel" -eq 1 ] && choice="$choice  [JOB-LEVEL]"
    printf '  %-32s %-46s %s\n' "$fname" "${triggers:-<none>}" "$choice"
  fi

  # The R4 exemption bookkeeping records that this file WAS scanned, before any refusal can
  # `continue` past it.
  # Recorded only in the R4 arm, a guard refused by R0 was additionally reported as "named in
  # EXEMPT_FILES but no such PR-triggered workflow was scanned" — a false second diagnostic that sends
  # the author looking for a rename (round 8, P2).
  if is_exempt "$fname"; then
    applied_exemptions="$applied_exemptions$fname "
  fi

  # ---- R0: what could not be read is not compliant ----------------------------------------
  if [ "$onparsed" -eq 0 ]; then
    r0_refusals=$((r0_refusals + 1))
    # The specific cause when the reader has one (an alias, a tag): the generic sentence describes
    # the SYMPTOM and would send the author looking for a missing `on:` that is in the file.
    fail "$fname: ${concwhy:-this check could not read any trigger from the \`on:\` section} — refusing to treat an unreadable workflow as non-PR. A workflow is not run without \`on:\`; a shape this reader cannot resolve must be fixed or modelled [R0]"
    continue
  fi
  if [ "$joblevel" -eq 1 ]; then
    r0_refusals=$((r0_refusals + 1))
    fail "$fname: declares a JOB-level \`concurrency:\`, which GitHub honours and this check does not model — hoist it to a workflow-level \`concurrency:\` (see --help) [R0]"
    continue
  fi
  if [ "${concbad:-0}" -eq 1 ]; then
    r0_refusals=$((r0_refusals + 1))
    # ONE message per cause: three shapes shared this line and two of them were then described as
    # "a sequence or an alias" that the file did not contain (round 5, P2).
    fail "$fname: ${concwhy:-an unreadable shape in this file} — an unreadable cancellation policy must not read as compliant [R0]"
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
  # The R3 hazard is that the block inside a callee groups two CALLERS together. A workflow that is
  # both
  # reusable AND PR-triggered must declare a cancelling block to satisfy R1, and in that
  # context that block is exactly this hazard — one block cannot serve both, so the combination is
  # refused rather than half-satisfied in silence (round 5, P2). `pipeline-compliance.yml` carries
  # both triggers but no block, so it keeps satisfying the R3 absence rule.
  if [ "$is_reusable" -eq 1 ] && [ "$is_pr" -eq 1 ] && [ "$hasconc" -eq 1 ]; then
    fail "$fname: triggers BOTH \`workflow_call\` and a pull-request event — R1 requires a cancelling block, and in the callee's context that block groups two CALLERS on one ref together (R3). Split the reusable workflow out [R3]"
  fi

  # ---- R2: a push-triggered workflow must never cancel a default-branch run ----------------
  if [ "$is_push" -eq 1 ]; then
    if [ "$hasconc" -eq 1 ]; then
      if [ "$cancel" = "true" ]; then
        if [ "$is_pr" -eq 1 ]; then
          fail "$fname: triggers BOTH \`push\` and a pull-request event, and cancels — one block cannot satisfy R1 (cancel on PR) and R2 (never cancel on push). Split the triggers into two workflows, as ci.yml (PR) and ci-main.yml (push) already are [R2]"
        else
          fail "$fname: triggers \`push\`, but \`concurrency.cancel-in-progress: true\` — a cancelled run on the default branch measured nothing and no replacement run is created for that head. Use \`cancel-in-progress: false\` (or drop the block) [R2]"
        fi
      elif [ -n "$cancel" ] && [ "$cancel" != "false" ]; then
        fail "$fname: triggers \`push\` and declares \`cancel-in-progress: '${cancel}'\` — only the literal \`false\` (or an absent key, which is GitHub's own default) is accepted on a push-triggered workflow [R2]"
      fi
    fi
  fi

  # ---- R1 / R4: PR entry points ------------------------------------------------------------
  # The stale-exemption arm is NOT gated on the file still being PR-triggered: a guard that DROPS its
  # PR trigger and gains a `concurrency:` block is exactly the regression the exemption must not
  # survive, and gating it on `is_pr` made both arms unreachable — the bookkeeping arm was satisfied
  # by the scan and this one by the missing trigger (round 9, P1).
  if is_exempt "$fname" && [ "$hasconc" -eq 1 ]; then
    fail "$fname: is an EXEMPT GUARD (#$EXEMPT_ISSUE) but now declares \`concurrency:\` — if the rail has been fixed, remove it from EXEMPT_FILES in scripts/check-workflow-concurrency.sh in the same change; if not, this re-arms the #$EXEMPT_ISSUE fail-open [R4]"
  fi

  if [ "$is_pr" -eq 1 ]; then
    if is_exempt "$fname"; then
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
        # The group a RUN will see: `github.workflow` is the NAME, not the file name, so
        # the comparison must resolve it — otherwise two workflows with different names that share
        # the canonical `${{ github.workflow }}-${{ github.ref }}` idiom would be false-red as
        # "they would cancel each other" (round 2 P2), when their runtime groups differ.
        identity="${wfname:-$fname}"
        # Canonicalise the expression before comparing: `${{github.workflow}}`,
        # `${{  github.workflow  }}` and `${{ github.workflow }}` are ONE expression, and substituting
        # only two literal spellings made the comparison read un-expanded templates — a correct pair
        # was refused as "they would cancel each other", and a genuinely shared group was missed
        # (round 5, P2). sed is anchored on `[^}]*` so two expressions on one line are two matches.
        # The identity is the workflow NAME, so every reference to it must be resolved before two
        # files are compared — including one inside the `format` idiom whose args are (0)-dash-(1)
        # style placeholders plus github.workflow, where a
        # template-level sed cannot reach it (its `}` closes the pattern first). Comparing the raw
        # template refused two DIFFERENT workflows as sharing one group (round 11, P2).
        resolved="$(printf '%s' "$group" | sed -e "s/github\.workflow_ref/${fname}_wfref/g")"
        resolved="$(printf '%s' "$resolved" | sed -e "s/github\.workflow\([^_]\)/$identity\1/g" -e "s/^github\.workflow$/$identity/")"
        resolved="$(printf '%s' "$resolved" | sed -E 's/\$\{\{[[:space:]]*([^}]*[^}[:space:]])[[:space:]]*\}\}/${{ \1 }}/g')"
        printf '%s\t%s\n' "$resolved" "$fname" >>"$TMP_GROUPS"
        # A per-commit variable makes every head (and every retry) its own group, so the block cancels
        # NOTHING — the exact defect it exists to prevent. This refusal must apply on BOTH paths: it
        # used to live only in the `pull_request` branch, so a `pull_request_target` group carrying
        # `github.run_id` alongside the PR number reported GREEN (round 4, P1). The list is a SUFFIX
        # test, not a closed set of spellings: `github.event.pull_request.head.sha` (the canonical
        # per-head key) contains no `github.sha` substring and passed before (round 4, P1).
        exprs="$(printf '%s' "$group" | grep -o '\${{[^}]*}}' | tr '\n' ' ')"
        case "$exprs" in
          *'.sha'*|*'_sha'*|*'run_id'*|*'run_number'*|*'run_attempt'*|*'head_commit.id'*)
            fail "$fname: \`concurrency.group\` ('$group') carries a PER-COMMIT variable — every head/attempt becomes its own group, so the block cancels nothing at all (an inert gate). Key it on \`github.ref\` / \`github.head_ref\` alone [R1]" ;;
          *)
            if has_trigger "$triggers" pull_request_target; then
              # On `pull_request_target`, `github.ref` is the BASE branch — but `github.head_ref` and
              # the PR number are both the pull request, so all three are correct keys here. Accepting
              # only the number refused a correct group and told the author it "collapses every PR
              # into one", which is not what a head_ref group does (round 5, P2).
              case "$group" in
                *'github.head_ref'*|*'github.event.pull_request.number'*|*'github.event.number'*) : ;;
                *) fail "$fname: \`pull_request_target\` sets \`github.ref\` to the BASE branch, so a group keyed on '$group' collapses every PR into one — key it on \`github.head_ref\` or the PR number (\`github.event.pull_request.number\`) [R1]" ;;
              esac
            else
              case "$group" in
                # The PR number is per-PR and stable across heads and `github.event.number` is that
                # same number — refusing either was a false red (rounds 4 and 5).
                *'github.ref'*|*'github.head_ref'*|*'github.workflow_ref'*|*'github.event.pull_request.number'*|*'github.event.number'*) : ;;
                *) fail "$fname: \`concurrency.group\` ('$group') is not keyed on the PR — expected \`github.ref\`, \`github.head_ref\`, \`github.workflow_ref\` or the PR number (\`github.event.pull_request.number\` / \`github.event.number\`) [R1]" ;;
              esac
            fi ;;
        esac
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
if [ "$MODE" = "repo" ] && [ "$pr_seen" -eq 0 ] && [ "$r0_refusals" -eq 0 ]; then
  echo "❌ no pull_request-triggered workflow was found in $ROOT/.github/workflows — R1 verified NOTHING (a broken glob or a renamed trigger must not read green)" >&2
  exit 2
fi
if [ "$MODE" = "repo" ] && [ "$r0_refusals" -gt 0 ]; then
  # A refused file already says why it could not be read; adding "no PR workflow was found" names a
  # SECOND cause (a rename or a glob hole) that does not exist, and sends the author after it
  # (round 10, P2 — the same class the exemption bookkeeping had in round 8).
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
