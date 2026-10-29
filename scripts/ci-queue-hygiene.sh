#!/usr/bin/env bash
# ci-queue-hygiene.sh — cancel workflow runs that are PROVABLY superseded, so they stop holding
# queue slots that a run somebody is waiting on needs.
#
# ⛔ WHY THIS EXISTS. Measured on daniel-ospina/tortoise, 2026-10-29: 46 non-completed runs, 19 of
# them on a head that was not any open PR's head, one `pending` for 21 h. GitHub creates a run's
# jobs PROGRESSIVELY (measured on run 40879897575: 4 jobs at 13:13:14, the 22-job matrix at
# 14:04:09, `ci-introduced-failure` at 15:14:16, `python-ci-gate` created 15:41:27 and only STARTED
# at 16:08:55), so a run nobody will read delays the required check on a PR's current head.
#
# ⛔ THE PREMISE, AND HOW IT IS MEASURED — a head being absent from the open-PR set is NOT proof it
# is dead. Four readings are reachable and only one is safe:
#   * the branch has an OPEN PR, owned by the SAME repository, whose head DIFFERS from this run's
#     -> provably not the head anyone will read. CANCEL.
#   * the branch has NO open PR at all -> NOT provable. It may be `release/2.0`, a `staging` line, a
#     `workflow_dispatch` branch, or a branch whose PR is being written right now. KEEP. (A head-set
#     diff cannot tell "no PR" from "not opened yet"; only a closed-PR read could, and that is a
#     second surface this tool deliberately does not take.)
#   * the run's head IS the open PR's head -> KEEP, unconditionally.
#   * the branch's PR is a FORK PR, or two open PRs share the branch name -> AMBIGUOUS. KEEP. A
#     branch name is not an identity: keying on it alone let a fork PR's `patch-1` decide the fate
#     of the repo's own `patch-1` (found by review as the round-2 blocking defect; latent here —
#     measured 0 forks of 20 open PRs — but structurally reachable). The map is therefore keyed on
#     the head REPOSITORY's full name plus the branch, and a key carrying two different heads is
#     refused outright. ⛔ The full repository name, not the owner: a same-owner fork (`o/r` vs
#     `o/r-fork`) colliding on a branch name is the same defect one level down (round-3 finding A).
#     A PR whose head repository cannot be NAMED — no `nameWithOwner`, or a name that is not exactly
#     `owner/name` — is UNKEYABLE: it is refused, never aliased onto a key.
# So the decision is keyed on (head repository full name, branch) -> current head, never on set
# absence and never on a bare branch name. "DIFFERS" is deliberate wording: this tool does not walk ancestry to prove the
# newer head descends from the older one — it only refuses to call a run current when the branch's
# open PR points somewhere else. Measured on the 2026-10-29 pass: 6/6 candidates were `ahead` with
# `behind_by=0`, i.e. the reading matched reality, but the claim it makes is the weaker one.
#
# ⛔ WHAT IT REFUSES TO DO, and why each refusal is deliberate:
#   * `in_progress` runs are never touched — a runner is already spent on them.
#   * runs on the DEFAULT branch are never touched. A `main` run validates main, and main's history
#     is what shipped; a newer commit does NOT make an earlier run useless, and main's arm is
#     deliberately not `cancel-in-progress` (see .github/workflows/python-ci.yml:126).
#   * runs on a branch whose head repository is not this repo are kept (a fork's run is not ours to
#     judge, and its branch name collides freely with ours).
#   * a run whose `head_sha` is absent is kept: without a head there is nothing to compare, and
#     cancelling on an unknown is the fail-open direction.
#   * runs younger than GRACE_S are never touched (a second commit landing while the PR head update
#     is in flight is not a supersession worth acting on).
#   * any surface that cannot be read COMPLETELY aborts the pass with nothing cancelled, and a repo
#     with ZERO open PRs is a FAIL-CLOSED rather than a pass: both surfaces agree on zero, so no run
#     could be proven superseded, and "nothing to do" would be a claim about a read that could
#     equally be a broken token. Reported as `open-PR list parsed to ZERO entries`, exit 2.
#   * MORE THAN `CI_HYGIENE_PR_LIMIT` open PRs (default 500) is a FAIL-CLOSED, not a partial read —
#     the tool becomes inert rather than guessing, and says so.
#
# ⚠️ DEFAULT IS DRY-RUN. `--apply` is required to cancel anything. EVERY decision is logged with its
# reason (KEEPs included), so a pass can be audited from the log alone, and the verdict line states
# how many rows were accounted for.
#
# Usage:
#   scripts/ci-queue-hygiene.sh [--repo <owner/name>] [--apply] [--max N] [--grace S] [--json]
#   scripts/ci-queue-hygiene.sh --self-test        # run the suite in scripts/ci-queue-hygiene.test.sh
#
# Exit: 0 = pass (including "nothing to do"); 1 = a cancel POST failed (some work WAS done — the log
# names which); 2 = FAIL-CLOSED (a surface could not be read completely, or a numeric bound could not
# be parsed, so nothing was cancelled and the pass is inconclusive, not clean); 64 = usage error
# (argument shape: a flag with no value, or a `--repo` that is not owner/name).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="${CI_HYGIENE_REPO:-daniel-ospina/tortoise}"
APPLY=0
MAX_CANCEL="${CI_HYGIENE_MAX:-50}"
GRACE_S="${CI_HYGIENE_GRACE_S:-300}"
JSON=0
GH_BIN="${GH_BIN:-gh}"
PR_LIMIT="${CI_HYGIENE_PR_LIMIT:-500}"

usage() { awk 'NR>1 && /^set -uo pipefail/{exit} NR>1{sub(/^# \{0,1\}/,""); print}' "$0"; }

# Argv: a value-taking flag with no value must be a USAGE ERROR, never a spin. `shift 2` with one
# positional left fails and leaves $# unchanged, so `while [ $# -gt 0 ]` would loop forever — a
# wedged lane with no diagnostic (found by review, reproduced under a 6 s watchdog).
need_value() { [ "$#" -ge 2 ] || { echo "$1 needs a value" >&2; exit 64; }; }

while [ $# -gt 0 ]; do
  case "$1" in
    --repo) need_value "$@"; REPO="$2"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --max) need_value "$@"; MAX_CANCEL="$2"; shift 2 ;;
    --grace) need_value "$@"; GRACE_S="$2"; shift 2 ;;
    --json) JSON=1; shift ;;
    --self-test) exec /bin/bash "$SCRIPT_DIR/ci-queue-hygiene.test.sh" ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 64 ;;
  esac
done

log() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }
fail_closed() { log "FAIL-CLOSED: $* — cancelling NOTHING"; exit 2; }

# `--repo` is interpolated into a SEARCH QUERY and into API paths, so its shape is validated rather
# than trusted: a value carrying a qualifier would silently widen the predicate (review F7).
case "$REPO" in
  # GitHub owner/repo names are [A-Za-z0-9._-]; anything else (a tab, a paren, a colon, a space) can
  # act as a qualifier separator in the search query below, so the shape is validated, not assumed.
  *[!A-Za-z0-9._/-]*) echo "--repo must be owner/name (got '$REPO')" >&2; exit 64 ;;
  */*/*|/*|*/) echo "--repo must be owner/name (got '$REPO')" >&2; exit 64 ;;
  */*) : ;;
  *) echo "--repo must be owner/name (got '$REPO')" >&2; exit 64 ;;
esac
case "$MAX_CANCEL" in ''|*[!0-9]*) fail_closed "MAX '$MAX_CANCEL' is not a number" ;; esac
case "$GRACE_S" in ''|*[!0-9]*) fail_closed "GRACE '$GRACE_S' is not a number" ;; esac
case "$PR_LIMIT" in ''|*[!0-9]*) fail_closed "PR_LIMIT '$PR_LIMIT' is not a number" ;; esac

work="$(mktemp -d "${TMPDIR:-/tmp}/ciqhyg.XXXXXX")" || { echo "mktemp failed" >&2; exit 2; }
trap 'rm -rf "$work"' EXIT

# ---------------------------------------------------------------------------- surfaces
read_pr_map() {
  local n total
  "$GH_BIN" pr list --repo "$REPO" --state open --limit "$PR_LIMIT" \
      --json headRefName,headRefOid,number,headRepositoryOwner,headRepository \
    >"$work/prs.json" 2>"$work/prs.err" || return 1
  python3 - "$work/prs.json" >"$work/prs.out" <<'PY'
import json, sys, collections
try:
    prs = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if not isinstance(prs, list):
    sys.exit(1)
seen = collections.defaultdict(set)
for p in prs:
    if not isinstance(p, dict):
        sys.exit(1)
    br = p.get("headRefName") or ""
    sha = p.get("headRefOid") or ""
    num = p.get("number") or ""
    if not br or not sha:
        sys.exit(1)
    # ⛔ THE KEY IS THE HEAD *REPOSITORY*, NOT THE OWNER. An owner cannot separate `o/repo` from
    # `o/repo-fork` — and GitHub supports forking into the SAME organisation as the parent, so an
    # owner-keyed map let a same-owner fork PR decide the fate of our identically-named branch
    # (round-3 finding A). `headRepositoryOwner` is kept only as a fallback for a gh that does not
    # return `headRepository`, and a PR whose head repository cannot be NAMED is keyed UNKEYABLE
    # rather than aliasing onto some empty-owner key (round-3 finding B).
    hrepo = p.get("headRepository") or {}
    full = (hrepo.get("nameWithOwner") or "")
    if not full:
        owner = ((p.get("headRepositoryOwner") or {}) or {}).get("login") or ""
        name = hrepo.get("name") or ""
        full = (owner + "/" + name) if (owner and name) else ""
    full = full.lower()                                     # owner/repo names are case-insensitive
    # A key is `repo` + "/" + `branch` with NO escaping, so a name that is not exactly `owner/name`
    # could print the SAME key as another repository's branch (`o/r` + `feat/x` vs `o/r/feat` + `x`).
    # GitHub cannot produce such a name today; refuse it anyway, because "cannot happen" is not a
    # structural guard — this is the same collision class as round-3 findings A and B, one level down.
    if full and full.count("/") != 1:
        full = ""
    if not full or full == "/":
        print("%s\tUNKEYABLE\t%d" % (br, num))
        continue
    seen[(full, br)].add((sha, num))
print("__COUNT__\t%d" % len(prs))
for (full, br), vals in seen.items():
    if len(vals) > 1:
        # A branch name that carries two different heads cannot decide anything: refuse the key.
        print("%s/%s\tAMBIGUOUS\t-" % (full, br))
    else:
        sha, num = list(vals)[0]
        print("%s/%s\t%s\t%s" % (full, br, sha, num))
PY
  [ $? -eq 0 ] || return 1
  n=$(awk -F'\t' '$1=="__COUNT__"{print $2; exit}' "$work/prs.out")
  case "${n:-}" in ''|*[!0-9]*) return 1 ;; esac
  grep -v '^__COUNT__' "$work/prs.out" >"$work/prs.raw"
  printf '%s' "$n" >"$work/prs.count" || return 1
  # TRUNCATION GUARD (review V4/F6). This is the surface whose truncation CANCELS live work, so its
  # completeness is checked against the search API's own open-PR total instead of being assumed.
  total="$("$GH_BIN" api -X GET search/issues -f q="repo:$REPO is:pr is:open" -f per_page=1 \
             --jq '.total_count' 2>"$work/search.err")" || {
    # Name the surface that actually failed: the pr-list call SUCCEEDED, so its stderr says nothing.
    cat "$work/search.err" >"$work/prs.err" 2>/dev/null
    printf 'open-PR TOTAL could not be read (search API)' >>"$work/prs.err"
    return 1
  }
  case "${total:-}" in
    ''|*[!0-9]*) printf 'open-PR TOTAL is not a number (%s)' "$total" >"$work/prs.err"; return 1 ;;
  esac
  printf '%s' "$total" >"$work/prs.total" || return 1
  if [ "$n" -ne "$total" ]; then
    printf 'open PRs read=%s but search reports total=%s (limit %s)' "$n" "$total" "$PR_LIMIT" \
      >"$work/prs.mismatch"
    return 3
  fi
  return 0
}

read_runs() {
  local status="$1" rc
  "$GH_BIN" api "repos/$REPO/actions/runs?status=$status&per_page=100" \
    >"$work/runs-$status.json" 2>"$work/runs-$status.err" || return 1
  # ⛔ Every field is emitted with a PLACEHOLDER rather than empty: `IFS=$'\t' read` treats tab as
  # whitespace and collapses adjacent empty fields, which shifted an absent `head_sha` into the
  # `created_at` slot and logged a valid run as `unparseable-age` (review F4). "-" cannot be confused
  # with a value, and the reader maps it back to empty.
  python3 - "$work/runs-$status.json" >"$work/$status.tsv" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    sys.exit(1)
if not isinstance(d, dict) or "workflow_runs" not in d:
    sys.exit(1)
if d.get("total_count", 0) > len(d["workflow_runs"]):
    sys.exit(2)                       # partial queue — distinguishable from a read error
for r in d["workflow_runs"]:
    repo_full = ((r.get("head_repository") or {}) or {}).get("full_name") or "-"
    print("%s\t%s\t%s\t%s\t%s\t%s" % (
        r.get("id") or "-", r.get("status") or "-", r.get("head_branch") or "-",
        r.get("head_sha") or "-", r.get("created_at") or "-", repo_full))
PY
  rc=$?
  case "$rc" in 0) return 0 ;; 2) return 2 ;; *) return 1 ;; esac
}

read_pr_map
pr_rc=$?
case "$pr_rc" in
  0) ;;
  3) fail_closed "the open-PR list is INCOMPLETE ($(cat "$work/prs.mismatch")) — a short list makes live runs look superseded" ;;
  *) fail_closed "could not read the open-PR surfaces ($(head -c 300 "$work/prs.err" 2>/dev/null))" ;;
esac
[ -s "$work/prs.raw" ] || fail_closed "open-PR list parsed to ZERO entries — both surfaces agree on zero, so nothing can be proven superseded"

for st in queued pending waiting; do
  read_runs "$st"
  case "$?" in
    0) ;;
    2) fail_closed "the '$st' queue read is INCOMPLETE (total_count reports more runs than the rows returned) — refusing to reason about a partial queue; re-read or raise the page size" ;;
    *) fail_closed "could not read the '$st' run list ($(head -c 300 "$work/runs-$st.err" 2>/dev/null))" ;;
  esac
done

default_branch="$("$GH_BIN" api "repos/$REPO" --jq '.default_branch' 2>"$work/repo.err")" \
  || fail_closed "could not read the default branch ($(head -c 300 "$work/repo.err"))"
[ -n "$default_branch" ] || fail_closed "default branch came back empty"

# ---------------------------------------------------------------------------- decision table
# De-duplicated by run id: a run that moves queued->pending between the three reads would otherwise
# be decided twice — POSTed twice, or stealing two --max slots (review V5).
cat "$work/queued.tsv" "$work/pending.tsv" "$work/waiting.tsv" \
  | awk -F'\t' '!seen[$1]++' >"$work/all.tsv"

rows=$(wc -l <"$work/all.tsv" | tr -d ' ')
cancelled=0; kept_current=0; kept_default=0; kept_nopr=0; kept_grace=0
kept_unresolved=0; kept_foreign=0; kept_ambiguous=0; kept_unknown=0; skipped_inprog=0; over_cap=0
: >"$work/cancel.tsv"
: >"$work/decisions.tsv"

while IFS=$'\t' read -r id status branch sha created repo_full; do
  [ -n "${id:-}" ] || continue
  [ "$branch" = "-" ] && branch=""
  [ "$sha" = "-" ] && sha=""
  [ "$created" = "-" ] && created=""
  [ "$repo_full" = "-" ] && repo_full=""
  if [ "${status:-}" = "in_progress" ]; then
    skipped_inprog=$((skipped_inprog+1))          # counted, so the audit arithmetic stays closed
    printf '%s\tSKIP\tin-progress(never touched)\n' "$id" >>"$work/decisions.tsv"; continue
  fi
  if [ "$branch" = "$default_branch" ]; then
    kept_default=$((kept_default+1))
    printf '%s\tKEEP\tdefault-branch(%s)\n' "$id" "$default_branch" >>"$work/decisions.tsv"; continue
  fi
  repo_lc="$(printf '%s' "$repo_full" | tr '[:upper:]' '[:lower:]')"
  repo_arg_lc="$(printf '%s' "$REPO" | tr '[:upper:]' '[:lower:]')"
  if [ -n "$repo_lc" ] && [ "$repo_lc" != "$repo_arg_lc" ]; then
    # A fork's head: its branch name collides freely with ours, so it is not ours to judge.
    kept_foreign=$((kept_foreign+1))
    printf '%s\tKEEP\tforeign-head-repo(%s)\n' "$id" "$repo_full" >>"$work/decisions.tsv"; continue
  fi
  if [ -z "$repo_lc" ]; then
    # Ownership is unprovable (the run reported no head repository), and an unprovable key must not
    # alias onto a PR whose own head repository is unknown either.
    kept_unknown=$((kept_unknown+1))
    printf '%s\tKEEP\tunknown-head-repo(ownership unprovable)\n' "$id" >>"$work/decisions.tsv"; continue
  fi
  # ⛔ BEFORE the empty-lookup arm: an unkeyable PR row cannot yield a sha, so testing it later
  # would report "no open PR on this branch" while an open PR exists (round-3 finding D).
  if awk -F'\t' -v b="$branch" '$1==b && $2=="UNKEYABLE"{found=1} END{exit !found}' "$work/prs.raw"; then
    kept_unknown=$((kept_unknown+1))
    printf '%s\tKEEP\tunkeyable-pr-head-repo(%s)\n' "$id" "$branch" >>"$work/decisions.tsv"; continue
  fi
  pr_sha="$(awk -F'\t' -v k="$repo_lc/$branch" '$1==k{print $2; exit}' "$work/prs.raw")"
  if [ -z "$pr_sha" ]; then
    kept_nopr=$((kept_nopr+1))
    printf '%s\tKEEP\tno-open-pr-on-branch(%s)\n' "$id" "$branch" >>"$work/decisions.tsv"; continue
  fi
  if [ "$pr_sha" = "AMBIGUOUS" ]; then
    kept_ambiguous=$((kept_ambiguous+1))
    printf '%s\tKEEP\tambiguous-branch-two-open-prs(%s)\n' "$id" "$branch" >>"$work/decisions.tsv"; continue
  fi
  if [ -z "$sha" ]; then
    kept_unresolved=$((kept_unresolved+1))
    printf '%s\tKEEP\tunknown-head(no head_sha on the run)\n' "$id" >>"$work/decisions.tsv"; continue
  fi
  if [ "$sha" = "$pr_sha" ]; then
    kept_current=$((kept_current+1))
    printf '%s\tKEEP\tcurrent-pr-head(%s)\n' "$id" "${sha:0:9}" >>"$work/decisions.tsv"; continue
  fi
  age="$(python3 -c '
import sys, datetime, time
s = sys.argv[1].replace("Z", "+00:00")
try:
    print(int(time.time() - datetime.datetime.fromisoformat(s).timestamp()))
except Exception:
    sys.exit(1)
' "$created" 2>/dev/null)" || { kept_unresolved=$((kept_unresolved+1)); printf '%s\tKEEP\tunparseable-age\n' "$id" >>"$work/decisions.tsv"; continue; }
  if [ "${age:-0}" -lt "$GRACE_S" ]; then
    kept_grace=$((kept_grace+1))
    printf '%s\tKEEP\twithin-grace(%ss<%ss)\n' "$id" "$age" "$GRACE_S" >>"$work/decisions.tsv"; continue
  fi
  if [ "$cancelled" -ge "$MAX_CANCEL" ]; then
    over_cap=$((over_cap+1)); printf '%s\tKEEP\tover-cap\n' "$id" >>"$work/decisions.tsv"; continue
  fi
  printf '%s\tCANCEL\tnot-the-open-pr-head(head %s, open PR head %s on %s, age %ss)\n' \
    "$id" "${sha:0:9}" "${pr_sha:0:9}" "$branch" "$age" >>"$work/decisions.tsv"
  printf '%s\t%s\n' "$id" "$branch" >>"$work/cancel.tsv"
  cancelled=$((cancelled+1))
done <"$work/all.tsv"

# EVERY decision is printed, KEEPs included: a pass that only logs its cancellations cannot be
# audited, and a silent KEEP is indistinguishable from a run the pass never saw.
while IFS=$'\t' read -r id verb reason; do
  [ -n "${id:-}" ] || continue
  printf '  %s %s %s\n' "$verb" "$id" "$reason"
done < <(awk -F'\t' 'NF>=3{print $1"\t"$2"\t"$3}' "$work/decisions.tsv")

accounted=$((cancelled+kept_current+kept_nopr+kept_default+kept_grace+kept_unresolved+kept_foreign+kept_ambiguous+kept_unknown+skipped_inprog+over_cap))
log "queue: queued=$(wc -l <"$work/queued.tsv" | tr -d ' ') pending=$(wc -l <"$work/pending.tsv" | tr -d ' ') waiting=$(wc -l <"$work/waiting.tsv" | tr -d ' ') open_prs=$(cat "$work/prs.count") default=$default_branch"
log "verdict: rows=$rows cancel=$cancelled keep_current_head=$kept_current keep_no_open_pr=$kept_nopr keep_default_branch=$kept_default keep_grace=$kept_grace keep_unresolved=$kept_unresolved keep_foreign_head=$kept_foreign keep_ambiguous=$kept_ambiguous keep_unknown_head_repo=$kept_unknown skip_in_progress=$skipped_inprog over_cap=$over_cap apply=$APPLY"
log "audit: $accounted of $rows rows accounted for"

if [ "$cancelled" -eq 0 ]; then
  log "nothing to cancel"
  [ "$JSON" = 1 ] && printf '{"cancelled":0,"apply":%s}\n' "$([ "$APPLY" = 1 ] && echo true || echo false)"
  exit 0
fi

if [ "$APPLY" -ne 1 ]; then
  log "DRY-RUN: $cancelled run(s) would be cancelled — re-run with --apply"
  [ "$JSON" = 1 ] && printf '{"cancelled":0,"would_cancel":%s,"apply":false}\n' "$cancelled"
  exit 0
fi

ok=0; failed=0
while IFS=$'\t' read -r id branch; do
  [ -n "${id:-}" ] || continue
  if "$GH_BIN" api -X POST "repos/$REPO/actions/runs/$id/cancel" >/dev/null 2>"$work/c.err"; then
    ok=$((ok+1)); log "cancelled $id ($branch)"
  else
    failed=$((failed+1)); log "cancel FAILED $id ($branch): $(head -c 300 "$work/c.err")"
  fi
done <"$work/cancel.tsv"

log "result: cancelled=$ok failed=$failed"
[ "$JSON" = 1 ] && printf '{"cancelled":%s,"failed":%s,"apply":true}\n' "$ok" "$failed"
[ "$failed" -eq 0 ] || exit 1
exit 0
