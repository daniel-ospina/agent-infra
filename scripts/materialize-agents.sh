#!/bin/bash
# materialize-agents.sh — regenerate a consumer repo's AGENTS.md as:
#   [full current AGENTS.base.md verbatim] + [repo-specific tail]
#
# The repo-specific tail is the portion of the consumer's existing AGENTS.md
# after the BASE-END marker (`<!-- AGENTS-BASE-END -->`). The script has
# three modes:
#
#   --check <repo>   Verify all universal rules reach pi: (a) every required base
#                    rule heading is present, then (b) the BASE-OWNED REGION matches
#                    the canonical template (line-subsequence when the file has no
#                    BASE-END marker; exact head compare when it does).
#                    Exit 0 = materialized (content drift is reported as a ⚠️ but
#                    is NON-blocking — rules still reach the model), 1 = stub/missing
#                    heading (authoring-time gate). Never exits 2.
#   --merge <repo>   Rewrite AGENTS.md = current base + existing tail after the
#                    marker (idempotent; safe to re-run after base changes).
#                    FIRST-TIME migration is NOT automatic — the human curates the
#                    tail once (see --new), because repo content must be deduped
#                    against universal sections that moved into the base head.
#   --new <repo> <tail-file>  First-time materialization: AGENTS.md = base +
#                    <tail-file> content, with BASE-END marker inserted.
#
# Why: pi's resource-loader reads ONLY local AGENTS.md/CLAUDE.md (walks up
# ancestors, never fetches URLs). A stub that "extends AGENTS.base.md by URL"
# delivers ZERO universal rules to the model (verified: tortoise/premise-labs
# sessions had 0 occurrences of the NEVER-PAUSE rule). Materialization is the
# only mechanism that works.
#
# Consumer AGENTS.md layout after materialization:
#   <AGENTS.base.md verbatim>            ← universal rules (mechanical, base-owned)
#   <!-- AGENTS-BASE-END -->             ← stable marker (never remove)
#   ## Repo-Specific Conventions         ← repo-owned tail
#   <repo content...>
set -euo pipefail

MARKER="<!-- AGENTS-BASE-END -->"

usage() { echo "usage: $0 --check|--merge <repo-dir> | --new <repo-dir> <tail-file>"; exit 2; }

[ $# -ge 2 ] || usage
MODE="$1"; REPO="$2"
# BASE_TEMPLATE is resolved lazily: only --new/--merge read it. --check
# greps the consumer's own AGENTS.md against its marker list and must work
# even when the template can't be resolved (consumer real-dir scripts/, no
# AGENT_INFRA_PATH) — otherwise a false "STUB" block masks a materialized
# file (#600 review P2).
resolve_base_template() {
  BASE_TEMPLATE="${AGENT_INFRA_PATH:-$(cd -P "$(dirname "$0")/.." && pwd -P)}/templates/AGENTS.base.md"
  [ -f "$BASE_TEMPLATE" ] || { echo "❌ base template missing: $BASE_TEMPLATE"; exit 1; }
}

# `--check` and `--merge` operate on an existing AGENTS.md; `--new` can create one.
if [ "$MODE" != "--new" ] && [ ! -f "$REPO/AGENTS.md" ]; then
  echo "❌ $REPO/AGENTS.md not found"
  exit 1
fi

# ── --check: structural marker gate + base-owned content drift check ────
if [ "$MODE" = "--check" ]; then
  f="$REPO/AGENTS.md"
  missing=0
  # Required base rule headings. `#### Hard Cap` is included because it is the
  # rule that BOUNDS every review loop in the base — a file missing it can pass
  # a bare "is it a stub?" check while silently losing a load-bearing rule
  # (#1027). Keep this list in sync with tests/materialize-agents/run.sh.
  for marker in \
    "HARD RULE: Auto-Continue" \
    "NEVER PAUSE WITHOUT A REASON" \
    "HARD RULE: Process Discipline" \
    "HARD RULE: Fix Broken Infrastructure" \
    "HARD RULE: Skill Compliance" \
    "Research Discipline" \
    "Debugging Discipline" \
    "Review Loop Protocol" \
    "#### Hard Cap"; do
    grep -qF "$marker" "$f" || { echo "   MISSING: $marker"; missing=1; }
  done
  if [ $missing -eq 0 ]; then
    # Materialized. Now check the BASE-OWNED REGION for drift vs the canonical
    # template. Drift is NON-blocking (exit 0) — the rules still reach the model
    # — but a plain ✅ would be a lie, so drift gets its own machine-readable
    # key (BASE-OWNED CONTENT DRIFTED) that callers can distinguish from clean.
    #
    # Read-only template resolution prefers the script's OWN physical parent,
    # then AGENT_INFRA_PATH. Script-first avoids a false drift warning when a
    # stale AGENT_INFRA_PATH shadows the checkout the script actually ships with;
    # the env fallback covers the real-dir `scripts/` consumer layout. If neither
    # resolves, the content compare is SKIPPED — and the skip is stated.
    BASE_T=""
    _self_dir="$(cd -P "$(dirname "$0")/.." 2>/dev/null && pwd -P)" || true
    if [ -n "$_self_dir" ] && [ -f "$_self_dir/templates/AGENTS.base.md" ]; then
      BASE_T="$_self_dir/templates/AGENTS.base.md"
    elif [ -n "${AGENT_INFRA_PATH:-}" ] && [ -f "$AGENT_INFRA_PATH/templates/AGENTS.base.md" ]; then
      BASE_T="$AGENT_INFRA_PATH/templates/AGENTS.base.md"
    fi
    if [ -z "$BASE_T" ]; then
      echo "✅ $REPO: materialized (9 base rule headings present; content compare skipped — base template not resolvable)"
      exit 0
    fi
    drift=0
    if grep -qE "^${MARKER}[[:space:]]*$" "$f"; then
      # Canonical marker present: the base-owned head region is well defined —
      # compare it exactly (repo edits in the head region are drift).
      HEAD=$(sed -n "1,/^${MARKER}[[:space:]]*$/p" "$f" | sed '$d' | tr -d '\r')
      TEMPLATE=$(tr -d '\r' < "$BASE_T")
      if [ "$HEAD" != "$TEMPLATE" ]; then
        echo "   ⚠️  base head differs from current AGENTS.base.md — refresh with --merge"
        drift=1
      fi
      CLEAN_MSG="base head matches AGENTS.base.md"
    else
      # No marker (legacy hand-written layout): the head region is UNDEFINED, so
      # require every base line to appear, in order, unmodified — a line
      # SUBSEQUENCE. Repo-specific additions are allowed (that is the repo-owned
      # tail). Operand order pins direction: template FIRST, so `^<` = "a base
      # line missing from the file".
      if DIFF_OUT=$(diff <(tr -d '\r' < "$BASE_T") <(tr -d '\r' < "$f")); then
        drc=0
      else
        drc=$?
      fi
      if [ "$drc" -eq 2 ]; then
        echo "   ⚠️  base-owned content compare could not run (diff exit 2)"
        echo "⚠️ $REPO: materialized (9 base rule headings present) but base-owned content compare could not run (internal error)"
        exit 0
      fi
      # `|| true` is REQUIRED: under `set -e` a `grep -c` that matches 0 lines
      # returns 1 and would abort — silently converting a CLEAN result into a
      # crash. This is the pipefail/exit-code control pinned by the suite.
      BASE_ONLY="$(grep -c '^<' <<<"$DIFF_OUT" || true)"
      if [ "${BASE_ONLY:-0}" -gt 0 ]; then
        echo "   ⚠️  base head differs from current AGENTS.base.md — ${BASE_ONLY} base line(s) missing/modified; refresh with --merge"
        drift=1
      fi
      CLEAN_MSG="all base lines present in order (repo additions allowed)"
    fi
    if [ "$drift" -eq 1 ]; then
      echo "⚠️ $REPO: materialized (9 base rule headings present) but BASE-OWNED CONTENT DRIFTED"
      exit 0
    fi
    echo "✅ $REPO: materialized (9 base rule headings present; ${CLEAN_MSG})"
    exit 0
  fi
  echo "⛔ $REPO: AGENTS.md is a STUB — universal rules never reach the model."
  if grep -qF "$MARKER" "$f"; then
    echo "   Fix: run  scripts/materialize-agents.sh --merge $REPO"
  else
    echo "   This AGENTS.md has no ${MARKER} marker (it predates the"
    echo "   materialization contract). --merge would refuse and --new would overwrite"
    echo "   it, so restore the MISSING heading(s) above from templates/AGENTS.base.md"
    echo "   by hand, then re-run --check."
  fi
  exit 1
fi

# ── --new: first-time materialization (base + curated tail) ────────────
if [ "$MODE" = "--new" ]; then
  [ $# -ge 3 ] || usage
  resolve_base_template
  TAIL="$3"
  [ -f "$TAIL" ] || { echo "❌ tail file missing: $TAIL"; exit 1; }
  if grep -qF "$MARKER" "$REPO/AGENTS.md" 2>/dev/null; then
    echo "⛔ $REPO already materialized (marker present). Use --merge to refresh."
    exit 1
  fi
  # Clobber guard: refuse --new when the existing AGENTS.md is NOT a
  # recognizable stub/empty — a marker-less file with substantial content
  # (the DMeer/eldato/agent-infra pre-marker layout) would be silently
  # overwritten by base + tail-file, dropping content the human forgot to
  # include in the tail (#600 review). Stub signature: SHORT (≤1500B, below
  # the pre-marker content files this guard protects) AND references the
  # base document by name/URL — NOT bare prose mention of the org (a
  # "belongs to the agent-infra org" note is content, not a stub).
  # Whitespace-only files count as empty (always safe); a stray BOM-only
  # remnant false-refuses fail-closed (remove the 3-byte file to proceed).
  STUB_SIG='AGENTS\.base\.md|AGENTS_BASE|github\.com/[-A-Za-z0-9_.]*/agent-infra'
  if [ -f "$REPO/AGENTS.md" ] && [ -s "$REPO/AGENTS.md" ] \
     && grep -q '[^[:space:]]' "$REPO/AGENTS.md"; then
    EXISTING_BYTES=$(wc -c < "$REPO/AGENTS.md")
    if [ "$EXISTING_BYTES" -gt 1500 ] \
       || ! grep -qE "$STUB_SIG" "$REPO/AGENTS.md"; then
      echo "⛔ $REPO/AGENTS.md already has content without a BASE-END marker —"
      echo "   refusing --new (would overwrite it). If it is a real stub, remove it"
      echo "   first or pass the existing file as the tail base for curation."
      exit 1
    fi
    echo "⚠️ overwriting existing marker-less AGENTS.md (stub heuristic: ≤1500B"
    echo "   + AGENTS.base.md reference) — ensure its content is in <tail-file>."
  fi
  { cat "$BASE_TEMPLATE"; echo; echo "$MARKER"; echo; cat "$TAIL"; } > "$REPO/AGENTS.md.new"
  mv "$REPO/AGENTS.md.new" "$REPO/AGENTS.md"
  echo "✅ $REPO: AGENTS.md materialized (base + repo tail). Review then commit."
  exit 0
fi

# ── --merge: refresh base head, preserve existing tail ─────────────────
if [ "$MODE" = "--merge" ]; then
  resolve_base_template
  f="$REPO/AGENTS.md"
  # Guard and extraction must use ONE matching rule. grep -qF is a substring
  # match (lenient) while `sed -n "/^marker$/"` is anchored (strict): a
  # trailing space or CRLF on the marker line made the guard pass but the sed
  # range match nothing → TAIL_BODY empty → silent tail truncation (#600
  # review P1). Use an anchored grep with [[:space:]]*$ that tolerates
  # trailing whitespace/CRLF.
  if ! grep -qE "^${MARKER}[[:space:]]*$" "$f"; then
    echo "⛔ $REPO has no BASE-END marker — cannot auto-merge. First materialize with --new."
    exit 1
  fi
  # Tail = everything after the marker line (marker line itself included once),
  # CR-normalized so the LF template head and CRLF tail don't produce a
  # mixed-EOL file (#600 review P2).
  TAIL_BODY=$(sed -n "/^${MARKER}[[:space:]]*$/,\$p" "$f" | tr -d '\r')
  # Safety: refuse a merge that would lose the tail (extraction produced
  # nothing below the marker but the file is longer than the marker alone).
  # The original is untouched until the new file is fully built + mv'd, so no
  # .bak is needed — a failed build never reaches mv (set -e).
  TAIL_LINES=$(printf '%s\n' "$TAIL_BODY" | sed '1d' | grep -c . || true)
  if [ "$TAIL_LINES" -eq 0 ]; then
    echo "⛔ $REPO: --merge found no content below the BASE-END marker — refusing"
    echo "   to overwrite (would drop the repo tail). Inspect $f manually."
    exit 1
  fi
  { cat "$BASE_TEMPLATE"; echo; echo "$MARKER"; echo; printf '%s\n' "$TAIL_BODY" | sed "1d;2{/^$/d;}"; } > "$f.new"
  mv "$f.new" "$f"
  echo "✅ $REPO: AGENTS.md base head refreshed (tail preserved)."
  exit 0
fi

usage
