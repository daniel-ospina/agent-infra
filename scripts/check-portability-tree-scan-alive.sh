#!/usr/bin/env bash
# check-portability-tree-scan-alive.sh — the whole-tree portability scan is OBSERVABLY alive.
#
# WHY THIS EXISTS (agent-infra#4210 acceptance 4): "The tree-wide run must be observably alive — its
# last-success timestamp is published, and staleness is itself a failure. A scheduled job that
# silently stops is an absence, and an absence is not a pass."
#
# ⛔ A SCHEDULED JOB CANNOT DETECT ITS OWN ABSENCE. `.github/workflows/portability-tree-scan.yml` can
# report its own success, but if the schedule is disabled, the file is renamed, or the workflow is
# parked, NOTHING runs — and a check that never runs looks exactly like a check that passed. So the
# freshness question is asked from OUTSIDE, in the lanes that run on every push (the bounded
# `script-validate` / `bash-suites` gate jobs), and an unreadable or missing answer is a REFUSAL, never
# a pass.
#
# ⛔ WHAT IS PUBLISHED, AND WHY THE ACTIONS API IS THE PUBLICATION. The batch workflow's own successful
# run IS the published last-success timestamp: `GET /repos/{o}/{r}/actions/workflows/<file>/runs?status=success`
# is durable, needs no write token, and cannot disagree with what actually ran. The alternative — the
# job writing a timestamp into a ref or a variable — would let the record outlive the run that was
# supposed to produce it, which is the fail-open this check exists to catch.
#
# BOOTSTRAP WINDOW, STATED: when the workflow has never completed successfully, freshly landing it
# would red the very PR that introduces it. In that ONE case the workflow object's `created_at` is used
# as the origin, so the first scheduled run has the same 72 h to appear. A workflow that never runs
# while its registration is older than the bound is STALE — the window closes on its own, and it is
# reported as a `NOTE bootstrap:` line rather than passing silently.
#
# USAGE
#   bash scripts/check-portability-tree-scan-alive.sh                 # $GITHUB_REPOSITORY / git remote
#   bash scripts/check-portability-tree-scan-alive.sh --repo o/name --max-age-hours 72
#   bash scripts/check-portability-tree-scan-alive.sh --workflow portability-tree-scan.yml
#
# EXIT: 0 fresh (or inside the bootstrap window, NAMED) · 1 STALE · 2 cannot read (never a pass)
#
# BASH 3.2-SAFE; this file is scanned by the detector it reports on, so it uses `box_iso_to_epoch`
# rather than its own `date -d` (a GNU-only spelling this repo's own rules forbid).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || { echo "unresolvable script dir" >&2; exit 2; }
REPO_ROOT="$(dirname "$HERE")"
# shellcheck source=lib/box.sh
. "$HERE/lib/box.sh"

REPO="${GITHUB_REPOSITORY:-}"
WORKFLOW="portability-tree-scan.yml"
MAX_HOURS="${PORTABILITY_TREE_SCAN_MAX_AGE_HOURS:-72}"

while [ $# -gt 0 ]; do
  case "$1" in
    --repo)          REPO="${2:?--repo needs owner/name}"; shift 2 ;;
    --workflow)      WORKFLOW="${2:?--workflow needs a file name}"; shift 2 ;;
    --max-age-hours) MAX_HOURS="${2:?--max-age-hours needs a number}"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$MAX_HOURS" in ''|*[!0-9]*) echo "❌ --max-age-hours must be a positive integer (got '$MAX_HOURS')" >&2; exit 2 ;; esac

# The repo can also be derived from the checkout, so a local run needs no environment at all. A repo
# that cannot be named is a refusal: the question ("when did it last succeed") is about a specific one.
if [ -z "$REPO" ]; then
  remote="$(git -C "$REPO_ROOT" config --get remote.origin.url 2>/dev/null)" || remote=""
  case "$remote" in
    git@github.com:*) REPO="${remote#git@github.com:}"; REPO="${REPO%.git}" ;;
    https://github.com/*) REPO="${remote#https://github.com/}"; REPO="${REPO%.git}" ;;
    '') ;;
    *)  ;;
  esac
fi
[ -n "$REPO" ] || { echo "❌ REFUSING: cannot name the repository (pass --repo owner/name, or set GITHUB_REPOSITORY)" >&2; exit 2; }
command -v gh >/dev/null 2>&1 || { echo "❌ REFUSING: gh is not installed — the run history is not readable, and an unreadable answer is not a fresh one" >&2; exit 2; }

# ── THE TWO READS, EACH A REFUSAL ON FAILURE ─────────────────────────────────────────────────────
# The stderr of each read is captured: a 404 has to be told apart from an outage (see below).
TMP_GH_ERR="$(mktemp "${TMPDIR:-/tmp}/portability-alive-XXXXXX")" || { echo "❌ mktemp" >&2; exit 2; }
trap 'rm -f "$TMP_GH_ERR"' EXIT
: >"$TMP_GH_ERR"
# ⛔ `|| true` WOULD BE THE WHOLE DEFECT: an empty read would fall through to the bootstrap window and
# certify a workflow that never ran. Every failure path here exits 2.
gh_err="$TMP_GH_ERR"
runs_json="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW/runs?status=success&per_page=1" 2>"$gh_err")" || {
  # ⛔ A 404 IS A DIFFERENT ANSWER FROM AN OUTAGE, AND THE DIFFERENCE MATTERS MOST ON THE PR THAT LANDS
  # THE WORKFLOW. A workflow file that is in THIS TREE but not yet registered in the repository is
  # "not landed yet" (the landing PR itself, which must not red on its own change); one that is in
  # NEITHER is a real absence and must refuse. Reading both as "cannot read" would red every PR until
  # the first merge, and reading both as bootstrap would let a deleted workflow stay green — so the
  # tree is the disambiguator, and any other failure still exits 2 below.
  if grep -Eq 'Not Found|HTTP 404|status 404' "$gh_err"; then
    if [ -f "$REPO_ROOT/.github/workflows/$WORKFLOW" ]; then
      echo "NOTE bootstrap: $WORKFLOW is in this tree but not yet registered in $REPO (it lands with this change). The freshness window starts when it is registered: the first successful scheduled run must appear within ${MAX_HOURS}h. Until then this guard cannot answer, and it says so rather than passing silently."
      exit 0
    fi
    echo "❌ REFUSING: $WORKFLOW is NOT registered in $REPO and is NOT present in this tree — the whole-tree portability assertion has no lane at all" >&2
    exit 2
  fi
  echo "❌ REFUSING: could not read the successful runs of $WORKFLOW in $REPO (the Actions API refused or is unreachable): $(head -2 "$gh_err" | tr '\n' ' ')" >&2
  exit 2
}
last_iso="$(printf '%s' "$runs_json" | awk -F'"' '{ for (i = 1; i <= NF; i++) if ($i == "updated_at") { print $(i + 2); exit } }')"
last_sha="$(printf '%s' "$runs_json" | awk -F'"' '{ for (i = 1; i <= NF; i++) if ($i == "head_sha") { print $(i + 2); exit } }')"
last_url="$(printf '%s' "$runs_json" | awk -F'"' '{ for (i = 1; i <= NF; i++) if ($i == "html_url") { print $(i + 2); exit } }')"

# `awk -F'"'` over JSON is deliberately primitive: the fields read here are flat strings, the script
# must run without jq (macOS ships none by default), and `gh --jq` would put a second JSON parser in
# the path of a gate that must work on both hosts.

now="$(date -u +%s 2>/dev/null)" || { echo "❌ REFUSING: could not read the clock" >&2; exit 2; }
case "$now" in ''|*[!0-9]*) echo "❌ REFUSING: the clock read '$now' is not an integer" >&2; exit 2 ;; esac
max_secs=$((MAX_HOURS * 3600))

if [ -n "$last_iso" ]; then
  last_epoch="$(box_iso_to_epoch "$last_iso" 2>/dev/null)" || last_epoch=""
  case "$last_epoch" in
    ''|*[!0-9]*) echo "❌ REFUSING: the last successful run reports '$last_iso', which is not an ISO-8601 instant — an unparseable timestamp is not a fresh one" >&2; exit 2 ;;
  esac
  age=$((now - last_epoch))
  # A success timestamped in the FUTURE is a clock or payload anomaly, not freshness: a negative age
  # would sail under every bound forever.
  if [ "$age" -lt 0 ]; then
    echo "❌ REFUSING: the last success ($last_iso) is in the FUTURE relative to this clock — refusing to certify freshness from a negative age" >&2
    exit 2
  fi
  if [ "$age" -le "$max_secs" ]; then
    echo "✅ the whole-tree portability scan ($WORKFLOW) is alive: last success ${last_iso} ($((age / 3600))h ago, bound ${MAX_HOURS}h) at ${last_sha:0:12}"
    [ -n "$last_url" ] && echo "   run: $last_url"
    exit 0
  fi
  echo "❌ STALE: the whole-tree portability scan ($WORKFLOW) last succeeded ${last_iso} ($((age / 3600))h ago), past the ${MAX_HOURS}h bound."
  echo "   At ${last_sha:0:12}${last_url:+  ($last_url)}"
  echo "   An absence is not a pass: the schedule may be disabled, the workflow parked, or the run failing."
  echo "   Re-run it: gh workflow run $WORKFLOW --repo $REPO"
  exit 1
fi

# Never succeeded. Two possibilities, and only one of them is acceptable — a freshly landed workflow
# inside its bootstrap window, or a workflow that has been dead since the day it was registered.
wf_json="$(gh api "repos/$REPO/actions/workflows/$WORKFLOW" 2>/dev/null)" || {
  echo "❌ REFUSING: $WORKFLOW has NO successful run AND its registration could not be read in $REPO" >&2
  exit 2
}
created_iso="$(printf '%s' "$wf_json" | awk -F'"' '{ for (i = 1; i <= NF; i++) if ($i == "created_at") { print $(i + 2); exit } }')"
created_epoch="$(box_iso_to_epoch "$created_iso" 2>/dev/null)" || created_epoch=""
case "$created_epoch" in
  ''|*[!0-9]*) echo "❌ REFUSING: $WORKFLOW has no successful run and its registration date ('$created_iso') is unreadable — cannot tell 'just landed' from 'never ran'" >&2; exit 2 ;;
esac
age=$((now - created_epoch))
[ "$age" -lt 0 ] && age=0
if [ "$age" -le "$max_secs" ]; then
  echo "NOTE bootstrap: $WORKFLOW has no successful run yet; it was registered ${created_iso} ($((age / 3600))h ago), inside the ${MAX_HOURS}h bootstrap window. The first scheduled run must appear before that window closes."
  exit 0
fi
echo "❌ STALE: $WORKFLOW has NEVER completed successfully in $REPO, and it has been registered for $((age / 3600))h (bound ${MAX_HOURS}h)."
echo "   This is the absence an absence-only check cannot see. Re-run it: gh workflow run $WORKFLOW --repo $REPO"
exit 1
