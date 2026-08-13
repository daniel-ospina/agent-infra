#!/usr/bin/env bash
# _research_append.sh — persist research findings to a research brief.
#
# Pipeline research stages dispatch this to append timestamped, source-tagged
# findings to the brief that `_research_path.sh` resolves:
#   - skills/issue-scoping Phase 1.5 (Sub-step C persist)
#   - (future) epic-research / epic-plan hook persistence
#
# Resolution order (identical to _research_path.sh):
#   1. Issue body `**Research:** <path>` field (issue-creation convention).
#      "none", empty, or a non-existent path → fall through.
#   2. Epic doc path (`--epic-path docs/epics/<slug>/plan.md`): sibling
#      research briefs `research-brief.md`, `research-brief.yaml`, `research.md`.
#
# New script (v4-adjacent semantics, deliberate deviations — #231 D8):
#   - v4's version errored on missing target; this one CREATE-IF-MISSING.
#   - v4 took positional args; this one uses flags (matches _research_path.sh).
#   - `## Raw Notes` is created if absent inside an existing brief.
#   - `gh issue edit` backfill is best-effort (`|| true`) — offline/gh-unavailable
#     sessions still create/append the local brief; backfill is silently skipped.
#
# Exit codes: 0 = success, 2 = usage error, 3 = brief path resolved but write failed.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: bash scripts/_research_append.sh \
    [--issue-body "$BODY"] [--epic-path "$EPIC_DOC_PATH"] \
    --append "<text>" [--create] [--source-tag "<tag>"] [--issue-number N] [--self-test]

  --issue-body <text>   GitHub issue body (optional). Resolution source for
                        the `**Research:**` field.
  --epic-path <path>    Epic doc path (optional). Fallback sibling research brief.
  --append "<text>"     Findings text to append (timestamped + source-tagged).
  --source-tag <tag>    Framing label: canonical|competitor|precedent|pitfalls|
                        adversarial|question (default: canonical).
  --create              Create the brief (header + `## Raw Notes` + `### Axis
                        Research` skeleton) if missing, and create `## Raw Notes`
                        inside an existing brief that lacks it.
  --issue-number N      Issue number for `gh issue edit` `**Research:**` backfill
                        (best-effort; requires gh auth, silently skipped offline).
  --self-test           Run the bash unit tests and exit.

Resolution note: with no --issue-body and no --epic-path, the script appends to
the epic sibling brief if one exists, otherwise exits 0 with nothing appended (documented no-op).


Exit: 0 = success, 2 = usage error, 3 = write failed.
EOF
}

ISSUE_BODY=""
EPIC_PATH=""
APPEND_TEXT=""
SOURCE_TAG="canonical"
DO_CREATE=0
ISSUE_NUMBER=""
SELF_TEST=0
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --issue-body)
      [[ $# -ge 2 ]] || { echo "Error: --issue-body requires a value" >&2; exit 2; }
      ISSUE_BODY="$2"; shift 2 ;;
    --epic-path)
      [[ $# -ge 2 ]] || { echo "Error: --epic-path requires a value" >&2; exit 2; }
      EPIC_PATH="$2"; shift 2 ;;
    --append)
      [[ $# -ge 2 ]] || { echo "Error: --append requires a value" >&2; exit 2; }
      APPEND_TEXT="$2"; shift 2 ;;
    --source-tag)
      [[ $# -ge 2 ]] || { echo "Error: --source-tag requires a value" >&2; exit 2; }
      case "$2" in
        canonical|competitor|precedent|pitfalls|adversarial|question) ;;
        *) echo "Error: --source-tag must be one of canonical|competitor|precedent|pitfalls|adversarial|question (got: $2)" >&2; exit 2 ;;
      esac
      SOURCE_TAG="$2"; shift 2 ;;
    --create)
      DO_CREATE=1; shift ;;
    --issue-number)
      [[ $# -ge 2 ]] || { echo "Error: --issue-number requires a value" >&2; exit 2; }
      [[ "$2" =~ ^[0-9]+$ ]] || { echo "Error: --issue-number must be numeric (got: $2)" >&2; exit 2; }
      ISSUE_NUMBER="$2"; shift 2 ;;
    --self-test)
      SELF_TEST=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

# ── Resolution (mirror of _research_path.sh) ────────────────────────────────
resolve_research_field() {
  local value
  value=$(printf '%s\n' "$ISSUE_BODY" | awk '/^\*\*Research:\*\*/ { sub(/^\*\*Research:\*\*[[:space:]]*/, ""); print; exit }')
  [[ -n "$value" ]] || return 1
  # Quoting-safe trim (code-review P3): xargs mangles quotes/backslashes.
  value="${value#"${value%%[![:space:]]*}"}"   # strip leading whitespace
  value="${value%"${value##*[![:space:]]}"}"   # strip trailing whitespace
  [[ -n "$value" ]] || return 1
  [[ "$value" == "none" || "$value" == "None" ]] && return 1
  printf '%s\n' "$value"
}

resolve_epic_sibling() {
  [[ -n "$EPIC_PATH" ]] || return 1
  local base
  if [[ -d "$EPIC_PATH" ]]; then base="$EPIC_PATH"; else base=$(dirname "$EPIC_PATH"); fi
  local candidate
  for candidate in "$base/research-brief.md" "$base/research-brief.yaml" "$base/research.md"; do
    [[ -f "$candidate" ]] || continue
    printf '%s\n' "$candidate"
    return 0
  done
  return 1
}

resolve_brief_path() {
  if [[ -n "$ISSUE_BODY" ]]; then
    if resolve_research_field; then return 0; fi
  fi
  if resolve_epic_sibling; then return 0; fi
  return 1
}

validate_brief_path() {
  # Arbitrary-path write protection (code-review P2): the resolved brief path is
  # written to, so constrain it — markdown/yaml suffix, no .git/ traversal, no
  # hidden basenames, must stay under the working-tree root.
  local brief="$1"
  case "$brief" in
    *.md|*.yaml) ;;          # allow markdown + yaml briefs
    *) echo "Error: resolved brief path is not a .md/.yaml file: $brief" >&2; return 1 ;;
  esac
  case "$brief" in
    */.git/*|*/.git|.git/*|*/.*|.[^/]*/*)
      echo "Error: refusing to write to a .git or hidden path: $brief" >&2; return 1 ;;
  esac
  local dir probe parent absdir root absroot orig_cwd
  orig_cwd=$(pwd)
  dir=$(dirname "$brief")
  # Walk up to the nearest EXISTING ancestor for the containment test — tolerates
  # create-into-missing-directory WITHOUT creating anything (cycle-3 P2: the mkdir
  # must not run before validation, or an out-of-tree path creates dirs pre-reject).
  probe="$dir"
  while ! cd "$probe" 2>/dev/null; do
    parent=$(dirname "$probe")
    [[ "$parent" == "$probe" ]] && { echo "Error: cannot resolve directory: $dir" >&2; return 1; }
    probe="$parent"
  done
  # The successful cd above leaves cwd AT the resolved directory — capture
  # it here. (Do NOT re-run `cd "$probe"` in a subshell: $probe may be a
  # RELATIVE path, and with cwd already mutated a second `cd docs/...`
  # fails, leaving absdir empty and rejecting valid relative briefs —
  # issue #1145.)
  absdir=$(pwd -P)
  cd "$orig_cwd"   # restore cwd before resolving the repo root (the walk mutated it)
  root=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
  absroot=$(cd "$root" && pwd -P)
  case "$absdir" in
    "$absroot"/*|"$absroot") ;;  # inside the working tree
    *) echo "Error: resolved brief path is outside the repo root: $brief" >&2; return 1 ;;
  esac
  return 0
}

# ── Persistence ─────────────────────────────────────────────────────────────
ensure_raw_notes() {
  # Create `## Raw Notes` section inside the brief if absent (D10 create-if-missing).
  if ! grep -q '^## Raw Notes' "$1"; then
    printf '\n## Raw Notes\n\n' >> "$1"
  fi
}

append_entry() {
  local brief="$1" text="$2" tag="$3"
  local ts
  ts=$(date +%Y-%m-%dT%H:%M:%S)
  ensure_raw_notes "$brief"
  # Append-only, timestamped, source-tagged entry (reverse-chronological within file).
  printf -- '- **%s** [%s] %s\n' "$ts" "$tag" "$text" >> "$brief"
}

create_brief() {
  local brief="$1"
  local dir
  dir=$(dirname "$brief")
  mkdir -p "$dir"
  if [[ ! -f "$brief" ]]; then
    cat > "$brief" <<'BRIEF'
# Research Brief

## Raw Notes

### Axis Research

BRIEF
  fi
}

backfill_research_field() {
  local brief="$1"
  [[ -n "$ISSUE_NUMBER" ]] || return 0
  command -v gh >/dev/null 2>&1 || return 0
  local tmp
  tmp=$(mktemp)
  trap 'rm -f "$tmp" "$tmp.new"' RETURN
  # gh has no single-field body edit — rewrite the body (replace **Research:** line, or
  # append it), then write back via --body-file. Best-effort: offline/gh-unavailable →
  # silently skipped (documented, not swallowed as success).
  if gh issue view "$ISSUE_NUMBER" --json body -q .body 2>/dev/null > "$tmp"; then
    if grep -q '^\*\*Research:\*\*' "$tmp"; then
      # code-review P3: pass the brief path via env (ENVIRON) — no -v string interpolation
      # (a quote/backslash in the path would corrupt the awk program).
      RESEARCH_BRIEF="$brief" awk '/^\*\*Research:\*\*/{print "**Research:** " ENVIRON["RESEARCH_BRIEF"]; next} {print}' "$tmp" > "$tmp.new" && mv "$tmp.new" "$tmp"
    else
      printf '\n**Research:** %s\n' "$brief" >> "$tmp"
    fi
    gh issue edit "$ISSUE_NUMBER" --body-file "$tmp" >/dev/null 2>&1 || true
  fi
}

# ── Self-test ───────────────────────────────────────────────────────────────
run_self_test() {
  local test_brief
  SELF_TEST_TMP=$(mktemp -d)   # script-global: bash tears down function locals before EXIT traps (P4)
  test_brief="$SELF_TEST_TMP/research-brief.md"
  trap 'rm -rf "$SELF_TEST_TMP"' EXIT

  # 1. create-on-missing
  create_brief "$test_brief"
  [[ -f "$test_brief" ]] || { echo "FAIL: create-on-missing"; exit 1; }
  grep -q '^## Raw Notes' "$test_brief" || { echo "FAIL: skeleton lacks Raw Notes"; exit 1; }
  grep -q '^### Axis Research' "$test_brief" || { echo "FAIL: skeleton lacks Axis Research"; exit 1; }

  # 2. append-preserves
  append_entry "$test_brief" "first finding" "canonical"
  append_entry "$test_brief" "second finding" "pitfalls"
  [[ $(grep -c -- '^- \*\*' "$test_brief") -eq 2 ]] || { echo "FAIL: append count"; exit 1; }

  # 3. brief-exists-but-no-Raw-Notes → created
  local legacy="$SELF_TEST_TMP/legacy.md"
  printf '# Legacy brief\n\n## Strategy\n\nstuff\n' > "$legacy"
  append_entry "$legacy" "third finding" "adversarial"
  grep -q '^## Raw Notes' "$legacy" || { echo "FAIL: Raw Notes not created"; exit 1; }
  [[ $(grep -c -- '^- \*\*' "$legacy") -eq 1 ]] || { echo "FAIL: legacy append count"; exit 1; }

  # 4. idempotency: appending twice doesn't duplicate the section
  local before
  before=$(grep -c '^## Raw Notes' "$test_brief")
  append_entry "$test_brief" "fourth finding" "precedent"
  [[ $(grep -c '^## Raw Notes' "$test_brief") -eq "$before" ]] || { echo "FAIL: Raw Notes duplicated"; exit 1; }

  # 5. resolution + real append via main (P0 regression guard — resolved path must be captured)
  #    Use a temp GIT repo so validate_brief_path's containment check passes end-to-end.
  local testrepo="$SELF_TEST_TMP/repo"
  mkdir -p "$testrepo"
  git -C "$testrepo" init -q
  local resolv="$testrepo/resolvable.md"
  printf '# Brief\n\n## Raw Notes\n\n' > "$resolv"
  local out
  out=$(cd "$testrepo" && bash "$SCRIPT_PATH" --issue-body "**Research:** $resolv" --append "resolved finding" --source-tag canonical 2>&1)
  [[ "$out" == *"Appended to $resolv"* ]] || { echo "FAIL: main resolution append: $out"; exit 1; }
  grep -q 'resolved finding' "$resolv" || { echo "FAIL: resolved append content missing"; exit 1; }
  # 6. no-resolvable-path → exit 0, nothing appended (documented no-op)
  local out2 rc2
  if out2=$(cd "$testrepo" && bash "$SCRIPT_PATH" --append "orphan" 2>&1); then rc2=0; else rc2=$?; fi
  [[ $rc2 -eq 0 ]] || { echo "FAIL: no-resolve exit code: $rc2"; exit 1; }
  echo "$out2" | grep -q "No research brief found" || { echo "FAIL: no-resolve no-op message: $out2"; exit 1; }
  [[ ! -f "$testrepo/orphan.md" ]] || { echo "FAIL: orphan appended despite no-op"; exit 1; }

  # 7. create-into-missing-directory (P3 guard)
  local fresh="$testrepo/nested/fresh-dir/brief.md"
  local out3
  out3=$(cd "$testrepo" && bash "$SCRIPT_PATH" --issue-body "**Research:** $fresh" --create --append "fresh brief" 2>&1)
  [[ "$out3" == *"Appended to $fresh"* ]] || { echo "FAIL: create-into-missing-dir: $out3"; exit 1; }
  grep -q 'fresh brief' "$fresh" || { echo "FAIL: fresh brief content missing"; exit 1; }

  # 8. out-of-tree path with --create → RC 3 AND no directory created (cycle-3 P2 guard)
  local outtree="$SELF_TEST_TMP/out-of-tree"
  local out4 rc4
  if out4=$(cd "$testrepo" && bash "$SCRIPT_PATH" --issue-body "**Research:** $outtree/evil/brief.md" --create --append "evil" 2>&1); then rc4=0; else rc4=$?; fi
  [[ $rc4 -eq 3 ]] || { echo "FAIL: out-of-tree RC (got $rc4): $out4"; exit 1; }
  echo "$out4" | grep -q "outside the repo root" || { echo "FAIL: out-of-tree message: $out4"; exit 1; }
  [[ ! -d "$outtree" ]] || { echo "FAIL: out-of-tree directory was created"; exit 1; }

  # 9. RELATIVE brief path (nested) resolves (issue #1145 — the cwd-mutating
  #    walk used to re-`cd docs/...` from the mutated cwd, fail, and reject
  #    valid relative paths with exit 3).
  mkdir -p "$testrepo/docs/research"
  local rel="$testrepo/docs/research/rel.md"
  printf '# Brief\n\n## Raw Notes\n\n' > "$rel"
  local out5 rc5
  if out5=$(cd "$testrepo" && bash "$SCRIPT_PATH" --issue-body "**Research:** docs/research/rel.md" --append "relative finding" --source-tag canonical 2>&1); then rc5=0; else rc5=$?; fi
  [[ $rc5 -eq 0 ]] || { echo "FAIL: relative path exit code (got $rc5): $out5"; exit 1; }
  echo "$out5" | grep -q "Appended to" || { echo "FAIL: relative append message: $out5"; exit 1; }
  grep -q 'relative finding' "$rel" || { echo "FAIL: relative append content missing"; exit 1; }

  echo "self-test OK"
  exit 0
}

[[ "$SELF_TEST" -eq 1 ]] && run_self_test

# ── Main ────────────────────────────────────────────────────────────────────
[[ -n "$APPEND_TEXT" ]] || { echo "Error: --append is required (or --self-test)" >&2; exit 2; }

if ! BRIEF=$(resolve_brief_path); then
  if [[ "$DO_CREATE" -eq 1 ]]; then
    echo "Error: --create needs a resolvable brief path (provide --issue-body or --epic-path)" >&2
    exit 2
  fi
  echo "No research brief found — nothing appended." >&2
  exit 0
fi

# P3 (review round 2): validate tolerates missing dirs by walking to the nearest
# existing ancestor — no mkdir here (cycle-3 P2: an out-of-tree path must NOT create
# directories pre-reject). create_brief does the mkdir -p after validation passes.
if ! validate_brief_path "$BRIEF"; then
  exit 3
fi

if [[ "$DO_CREATE" -eq 1 ]]; then
  create_brief "$BRIEF"
fi

if [[ ! -f "$BRIEF" ]]; then
  echo "Error: brief '$BRIEF' does not exist (use --create)" >&2
  exit 3
fi

if ! append_entry "$BRIEF" "$APPEND_TEXT" "$SOURCE_TAG"; then
  echo "Error: failed to append to '$BRIEF'" >&2
  exit 3
fi

backfill_research_field "$BRIEF"
echo "Appended to $BRIEF"
