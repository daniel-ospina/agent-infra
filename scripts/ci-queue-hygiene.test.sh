#!/usr/bin/env bash
# ci-queue-hygiene.test.sh — hermetic suite for scripts/ci-queue-hygiene.sh.
#
# Hermetic by construction: every GitHub surface the script touches is served by the stub `gh` on
# PATH, so the suite proves the DECISION TABLE, not GitHub's availability. The stub RECORDS every
# POST, so "cancelled nothing" is asserted from the transport, never from a log line.
#
# ⛔ THE ASSERTIONS THAT MATTER MOST are the refusals, because every one of them stops this tool from
# destroying work it exists to protect: an unreadable/empty/incomplete open-PR list (f/f2/f5/f6), a
# branch with no open PR (a2 — "no PR" is NOT "dead"), a FORK PR whose branch name collides with
# ours (a3), two open PRs sharing a branch name (a4), a default-branch run (c), and an argv that
# would otherwise spin forever (l).
set -uo pipefail

SCRIPT="${1:-$(cd "$(dirname "$0")" && pwd)/ci-queue-hygiene.sh}"
[ -f "$SCRIPT" ] || { echo "missing $SCRIPT" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/ciqhyg-test.XXXXXX")" || exit 2
trap 'rm -rf "$WORK"' EXIT
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL+1)); printf '  ❌ %s\n' "$1"; }
eq()   { if [ "$2" = "$3" ]; then ok "$1 ($3)"; else bad "$1 — want '$3', got '$2'"; fi; }

mkdir -p "$WORK/bin" "$WORK/fx"
cat >"$WORK/bin/gh" <<'STUB'
#!/usr/bin/env bash
FX="${FIXTURE_DIR:?}"
POSTS="${POSTS_FILE:?}"
all="$*"
case "$all" in
  "pr list"*)
    [ -f "$FX/prs.fail" ] && { echo "gh: HTTP 502 (pr list stub)" >&2; exit 1; }
    cat "$FX/prs.json"; exit 0 ;;
esac
case "$all" in
  *search/issues*)
    [ -f "$FX/search.fail" ] && { echo "gh: HTTP 502 (search stub)" >&2; exit 1; }
    cat "$FX/search_total"; exit 0 ;;
esac
case "$all" in
  *"/actions/runs?status=queued"*) [ -f "$FX/queued.fail" ] && { echo "gh: HTTP 502 (queued stub)" >&2; exit 1; }; cat "$FX/queued.json"; exit 0 ;;
  *"/actions/runs?status=pending"*) cat "$FX/pending.json"; exit 0 ;;
  *"/actions/runs?status=waiting"*) cat "$FX/waiting.json"; exit 0 ;;
esac
case "$all" in
  *"-X POST"*"/cancel")
    if [ -f "$FX/cancel.fail" ]; then echo "gh: HTTP 502 (cancel stub)" >&2; exit 1; fi
    id="$(printf '%s' "$all" | sed -n 's#.*actions/runs/\([0-9]*\)/cancel.*#\1#p')"
    echo "$id" >>"$POSTS"; exit 0 ;;
esac
case "$all" in
  *"--jq .default_branch"*) printf '%s\n' "${FIXTURE_DEFAULT:-main}"; exit 0 ;;
esac
echo "gh stub: unhandled args: $all" >&2; exit 1
STUB
chmod +x "$WORK/bin/gh"

# fixture "<repo>:<branch>:<sha> ..."   (repo is the PR's head REPOSITORY full name, or "" if unknown)
# run specs: "<id> <branch> <sha> <age_s> [<status>] [<head_repo_full_name>]"
# A run defaults to this repo ("o/r"); pass another value to model a fork's head.
fixture() {
  rm -rf "$WORK/fx"; mkdir -p "$WORK/fx"
  local prs="$1"; shift
  python3 - "$WORK/fx" "$prs" "$@" <<'PY'
import json, sys, datetime
fx, prs = sys.argv[1], sys.argv[2]
rows = []
for i, item in enumerate([p for p in prs.split() if p]):
    repo, branch, sha = item.split(":")
    row = {"headRefName": branch, "headRefOid": sha, "number": i + 1}
    if repo:
        row["headRepository"] = {"nameWithOwner": repo}
        row["headRepositoryOwner"] = {"login": repo.split("/")[0]}
    else:
        # a PR whose head repository cannot be named: no headRepository, no owner
        row["headRepositoryOwner"] = {}
    rows.append(row)
json.dump(rows, open(fx + "/prs.json", "w"))
open(fx + "/search_total", "w").write(str(len(rows)))
now = datetime.datetime.now(datetime.timezone.utc)
def run(rid, branch, sha, age, status, repo_full):
    r = {"id": int(rid), "status": status, "head_branch": branch,
         "created_at": (now - datetime.timedelta(seconds=int(age))).strftime("%Y-%m-%dT%H:%M:%SZ")}
    if sha != "-":
        r["head_sha"] = sha           # "-" models an ABSENT field, not an empty string
    r["head_repository"] = {"full_name": repo_full}
    return r
queued, pending, waiting = [], [], []
for spec in sys.argv[3:]:
    parts = spec.split()
    rid, branch, sha, age = parts[0], parts[1], parts[2], parts[3]
    status = parts[4] if len(parts) > 4 else "queued"
    repo_full = parts[5] if len(parts) > 5 else "o/r"
    row = run(rid, branch, sha, age, status, repo_full)
    bucket = {"queued": queued, "pending": pending, "waiting": waiting}.get(status, queued)
    bucket.append(row)
for name, rows_ in (("queued", queued), ("pending", pending), ("waiting", waiting)):
    json.dump({"total_count": len(rows_), "workflow_runs": rows_}, open(fx + "/" + name + ".json", "w"))
PY
}

run() {
  : >"$WORK/posts"
  OUT="$(PATH="$WORK/bin:$PATH" FIXTURE_DIR="$WORK/fx" POSTS_FILE="$WORK/posts" \
        HOME="$WORK" /bin/bash "$SCRIPT" --repo o/r "$@" 2>&1)"; RC=$?
}
posts() { wc -l <"$WORK/posts" | tr -d ' '; }
has()   { printf '%s' "$OUT" | grep -qF -- "$1"; }

echo "ci-queue-hygiene suite — $SCRIPT"

echo; echo "(a) a stale head on a branch whose open PR has moved on is cancelled"
fixture "o/r:feat/dead:aaa999" "100 feat/dead aaa111 3600"
run --apply
eq "exit" "$RC" 0
eq "posts" "$(posts)" 1
has "CANCEL 100 not-the-open-pr-head" && ok "decision names the reading" || bad "no CANCEL line"

echo; echo "(a2) ⛔ a branch with NO open PR is NOT dead: keep (release lines, staging, a PR being written)"
fixture "o/r:other:aaa111" "110 release/2.0 rel0sha 86400"
run --apply
eq "posts" "$(posts)" 0
has "no-open-pr-on-branch(release/2.0)" && ok "reason names the refusal" || bad "no-PR refusal missing"

echo; echo "(a3) ⛔ a FORK PR (different owner) whose branch name collides with ours cannot decide our run"
fixture "stranger/fork:patch-1:forkhead0" "120 patch-1 localhead 86400"
run --apply
eq "posts" "$(posts)" 0
has "no-open-pr-on-branch(patch-1)" && ok "collision does not match the fork PR" || bad "fork collision matched: $(printf '%s' "$OUT" | grep '  CANCEL\|  KEEP 120')"

echo "(a3c) ⛔ a SAME-OWNER fork (o/r-fork) colliding on the branch name cannot decide our run either"
fixture "o/r-fork:patch-1:forkhead0" "121 patch-1 localhead 86400"
run --apply
eq "posts (same-owner fork)" "$(posts)" 0
has "no-open-pr-on-branch(patch-1)" && ok "same-owner fork is not our PR" || bad "same-owner fork matched: $(printf '%s' "$OUT" | grep '  CANCEL 121')"

echo "(a3d) ⛔ a PR whose head repository cannot be NAMED is a KEEP (it must not alias onto /branch)"
fixture ":patch-1:somehead" "122 patch-1 localhead 86400"
run --apply
eq "posts (unkeyable PR)" "$(posts)" 0
has "unkeyable-pr-head-repo(patch-1)" && ok "unkeyable PR refused" || bad "unkeyable PR not refused: $(printf '%s' "$OUT" | grep '  CANCEL 122')"

echo "(a3b) ⛔ a run whose own head repository is a FORK is kept outright"
fixture "o/r:feat/x:aaabbb" "130 feat/x ccceee 86400 queued fork/r"
run --apply
eq "posts" "$(posts)" 0
has "foreign-head-repo(fork/r)" && ok "foreign head named" || bad "foreign head not recognised"

echo "(a3f) ⛔ an UPPER-CASE head_repository on the run is still OUR repository (case-insensitive both ways)"
fixture "o/r:feat/x:aaabbb" "136 feat/x ccceee 86400 queued O/R"
run --apply
case "$OUT" in *"foreign-head-repo"*) bad "own run read as foreign because of case" ;; *) ok "run repo case folded" ;; esac
has "CANCEL 136" && ok "and it is still decided" || bad "run not decided"

echo "(a3e) --repo case does not make our own runs foreign (owner/repo names are case-insensitive)"
fixture "o/r:feat/x:aaabbb" "135 feat/x ccceee 86400"
: >"$WORK/posts"
OUT="$(PATH="$WORK/bin:$PATH" FIXTURE_DIR="$WORK/fx" POSTS_FILE="$WORK/posts" HOME="$WORK" \
      /bin/bash "$SCRIPT" --repo O/R --apply 2>&1)"; RC=$?
case "$OUT" in *"foreign-head-repo"*) bad "own runs read as foreign under --repo O/R" ;; *) ok "case-insensitive repo identity" ;; esac
has "CANCEL 135" && ok "still decides the run (superseded) under an upper-case --repo" || bad "run not decided under --repo O/R"

echo "(a4) ⛔ two open PRs sharing a branch name are AMBIGUOUS: keep, never cancel"
fixture "o/r:patch-1:headA o/r:patch-1:headB" "140 patch-1 headC 86400"
run --apply
eq "posts" "$(posts)" 0
has "ambiguous-branch-two-open-prs(patch-1)" && ok "ambiguity refused" || bad "ambiguity not refused"

echo; echo "(b) a run on an open PR's CURRENT head is kept"
fixture "o/r:feat/live:aaa111" "200 feat/live aaa111 3600"
run --apply
eq "posts" "$(posts)" 0
has "keep_current_head=1" && ok "counted" || bad "not counted"

echo; echo "(c) a default-branch run is kept even when its branch head has moved on"
fixture "o/r:main:zzz999" "300 main zzz000 3600"
run --apply
eq "posts" "$(posts)" 0
has "keep_default_branch=1" && ok "counted" || bad "not counted"

echo; echo "(d) a run inside the grace window is kept"
fixture "o/r:feat/fresh:newsha" "400 feat/fresh bbb000 5"
run --apply --grace 300
eq "posts" "$(posts)" 0
has "within-grace" && ok "grace reason logged" || bad "grace reason missing"

echo "(d2) both directions, 60 s of margin each side (age is re-measured at run time)"
fixture "o/r:feat/a:a2" "501 feat/a a1 360"
run --apply --grace 300; eq "age360 posts" "$(posts)" 1
fixture "o/r:feat/b:b2" "502 feat/b b1 240"
run --apply --grace 300; eq "age240 posts" "$(posts)" 0

echo; echo "(e) DRY-RUN is the default: it reports, it does not cancel"
fixture "o/r:feat/dead:ccc999" "500 feat/dead ccc000 3600"
run
eq "posts" "$(posts)" 0
eq "exit" "$RC" 0
has "DRY-RUN: 1 run(s) would be cancelled" && ok "announces the count" || bad "dry-run line missing"

echo; echo "(f) ⛔ an UNREADABLE open-PR list aborts the pass and cancels NOTHING"
fixture "o/r:x:y" "600 feat/dead ddd000 3600"
: >"$WORK/fx/prs.fail"
run --apply
eq "exit (fail-closed)" "$RC" 2
eq "posts" "$(posts)" 0
has "FAIL-CLOSED" && ok "named as fail-closed" || bad "no FAIL-CLOSED line"

echo "(f2) ⛔ a PR list that parses to ZERO entries aborts the pass"
fixture "" "610 feat/dead eee000 3600"
run --apply
eq "exit (fail-closed)" "$RC" 2
eq "posts" "$(posts)" 0

echo "(f3) ⛔ an unreadable QUEUE aborts the pass, naming the queue"
fixture "o/r:feat/dead:fff999" "620 feat/dead fff000 3600"
: >"$WORK/fx/queued.fail"
run --apply
eq "exit (fail-closed)" "$RC" 2
eq "posts" "$(posts)" 0
has "queued" && ok "names the queue surface" || bad "surface not named"

echo "(f4) ⛔ a queue LARGER than one page aborts the pass, NAMING the queue"
fixture "o/r:feat/x:ggg999"
python3 - "$WORK/fx/queued.json" <<'PY'
import json, sys, datetime
now = datetime.datetime.now(datetime.timezone.utc)
row = {"id": 700, "status": "queued", "head_branch": "feat/x", "head_sha": "ggg000",
       "created_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"), "head_repository": {"full_name": "o/r"}}
json.dump({"total_count": 250, "workflow_runs": [row]}, open(sys.argv[1], "w"))
PY
run --apply
eq "exit (fail-closed)" "$RC" 2
eq "posts" "$(posts)" 0
# The message must name what was MEASURED (a count mismatch), not an unmeasured page limit: the
# guard compares total_count against the rows returned and never against 100 (round-4 N-1).
has "INCOMPLETE" && ok "names the partial queue" || bad "reason did not name the partial queue"

echo "(f5) ⛔ an INCOMPLETE open-PR list (read < search total) aborts the pass"
fixture "o/r:feat/dead:hhh999" "720 feat/dead hhh000 3600"
printf '501' >"$WORK/fx/search_total"
run --apply
eq "exit (fail-closed)" "$RC" 2
eq "posts" "$(posts)" 0
has "INCOMPLETE" && ok "names incompleteness" || bad "incompleteness not named"

echo "(f5b) the guard is symmetric: more rows read than the search total also aborts"
fixture "o/r:feat/dead:hhh999o:feat/other:iii999" "721 feat/dead hhh001 3600"
printf '1' >"$WORK/fx/search_total"
run --apply
eq "exit (fail-closed)" "$RC" 2
eq "posts" "$(posts)" 0

echo "(f6) ⛔ an unreadable search total aborts the pass, naming the SEARCH surface"
fixture "o/r:feat/dead:iii999" "730 feat/dead iii000 3600"
: >"$WORK/fx/search.fail"
run --apply
eq "exit (fail-closed)" "$RC" 2
eq "posts" "$(posts)" 0
has "TOTAL could not be read (search API)" && ok "names the search surface" || bad "wrong surface named: $(printf '%s' "$OUT" | grep FAIL-CLOSED)"

echo; echo "(g) --max caps the cancellations in one pass"
fixture "o/r:feat/a:new1" "801 feat/a j1 3600" "802 feat/a j2 3600" "803 feat/a j3 3600"
run --apply --max 2
eq "posts (capped)" "$(posts)" 2
has "over_cap=1" && ok "over-cap counted" || bad "over-cap not counted"

echo; echo "(h) an unparseable created_at is a KEEP, never a cancel"
fixture "o/r:feat/bad:k999"
python3 - "$WORK/fx/queued.json" <<'PY'
import json, sys
json.dump({"total_count": 1, "workflow_runs": [{"id": 900, "status": "queued",
  "head_branch": "feat/bad", "head_sha": "iii000", "created_at": "not-a-time",
  "head_repository": {"full_name": "o/r"}}]}, open(sys.argv[1], "w"))
PY
run --apply
eq "posts" "$(posts)" 0
has "keep_unresolved=1" && ok "counted" || bad "not counted"

echo "(h2) ⛔ an ABSENT head_sha is a KEEP (nothing to compare => unprovable), not a cancel"
fixture "o/r:feat/nosha:aaabbb" "910 feat/nosha - 3600"
run --apply
eq "posts" "$(posts)" 0
has "unknown-head(no head_sha on the run)" && ok "reason names the unknown head" || bad "not decided: $(printf '%s' "$OUT" | grep '  KEEP 910')"

echo "(h3) ⛔ an ABSENT head_repository is a KEEP: ownership is unprovable, so the branch key cannot match"
fixture "o/r:feat/x:aaabbb"
python3 - "$WORK/fx" <<'PY'
import json, sys, datetime
fx = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
row = {"id": 920, "status": "queued", "head_branch": "feat/x", "head_sha": "cccddd",
       "created_at": (now - datetime.timedelta(seconds=3600)).strftime("%Y-%m-%dT%H:%M:%SZ")}
json.dump({"total_count": 1, "workflow_runs": [row]}, open(fx + "/queued.json", "w"))
PY
run --apply
eq "posts (unknown owner)" "$(posts)" 0
has "unknown-head-repo(ownership unprovable)" && ok "unprovable ownership named as such" || bad "reason wrong: $(printf '%s' "$OUT" | grep '  KEEP 920')"

echo; echo "(i) nothing to do exits 0 and POSTs nothing"
fixture "o/r:feat/live:aaa111" "1000 feat/live aaa111 3600"
run --apply
eq "posts" "$(posts)" 0
eq "exit" "$RC" 0
has "nothing to cancel" && ok "announces nothing to do" || bad "missing nothing-to-do line"

echo; echo "(j) an in_progress run is never touched AND stays visible in the audit"
fixture "o/r:feat/live:aaa111" "1100 feat/dead zzz111 3600 in_progress"
run --apply
eq "posts" "$(posts)" 0
has "skip_in_progress=1" && ok "skip counted" || bad "skip not counted"
has "audit: 1 of 1 rows accounted for" && ok "audit arithmetic closes" || bad "audit does not close"

echo; echo "(k) a run that moves queued->pending between reads is decided ONCE"
fixture "o/r:feat/dead:yyy999"
python3 - "$WORK/fx" <<'PY'
import json, sys, datetime
fx = sys.argv[1]
now = datetime.datetime.now(datetime.timezone.utc)
row = {"id": 1200, "status": "queued", "head_branch": "feat/dead", "head_sha": "yyy000",
       "created_at": (now - datetime.timedelta(seconds=3600)).strftime("%Y-%m-%dT%H:%M:%SZ"),
       "head_repository": {"full_name": "o/r"}}
json.dump({"total_count": 1, "workflow_runs": [row]}, open(fx + "/queued.json", "w"))
row2 = dict(row); row2["status"] = "pending"
json.dump({"total_count": 1, "workflow_runs": [row2]}, open(fx + "/pending.json", "w"))
PY
run --apply
eq "posts (de-duplicated)" "$(posts)" 1
has "rows=1" && ok "row count de-duplicated" || bad "rows not de-duplicated"

echo; echo "(l) ⛔ a value-taking flag with NO value is a usage error, never a spin"
for flag in --max --grace --repo; do
  : >"$WORK/posts"
  OUT="$(PATH="$WORK/bin:$PATH" FIXTURE_DIR="$WORK/fx" POSTS_FILE="$WORK/posts" \
        HOME="$WORK" perl -e 'alarm shift; exec @ARGV' 10 /bin/bash "$SCRIPT" "$flag" 2>&1)"; RC=$?
  eq "$flag exit" "$RC" 64
done

echo; echo "(l2) ⛔ a --repo carrying a search qualifier is refused (it would widen the predicate)"
: >"$WORK/posts"
OUT="$(PATH="$WORK/bin:$PATH" FIXTURE_DIR="$WORK/fx" POSTS_FILE="$WORK/posts" HOME="$WORK" \
      /bin/bash "$SCRIPT" --repo "o/r is:closed" 2>&1)"; RC=$?
eq "--repo qualifier exit" "$RC" 64

echo "(l2c) ⛔ a NON-NUMERIC --max / --grace is FAIL-CLOSED (2), not silently 0"
for pair in "--max abc" "--grace x1"; do
  # shellcheck disable=SC2086
  OUT="$(PATH="$WORK/bin:$PATH" FIXTURE_DIR="$WORK/fx" POSTS_FILE="$WORK/posts" HOME="$WORK" \
        /bin/bash "$SCRIPT" $pair 2>&1)"; RC=$?
  eq "exit for '$pair'" "$RC" 2
  case "$OUT" in *"is not a number"*) ok "'$pair' names the defect" ;; *) bad "'$pair' did not name it: $OUT" ;; esac
done
OUT="$(PATH="$WORK/bin:$PATH" FIXTURE_DIR="$WORK/fx" POSTS_FILE="$WORK/posts" HOME="$WORK" \
      CI_HYGIENE_MAX=notanumber /bin/bash "$SCRIPT" 2>&1)"; RC=$?
eq "exit for CI_HYGIENE_MAX=notanumber" "$RC" 2

echo "(a3g) ⛔ a head repository that is not exactly owner/name is UNKEYABLE (no key can collide)"
fixture "o/r/feat:x:head9" "150 x y 86400"
run --apply
eq "posts (3-segment repo)" "$(posts)" 0
has "unkeyable-pr-head-repo(x)" && ok "3-segment name refused as unkeyable" || bad "3-segment name was keyed"

echo "(l2b) ⛔ other query separators are refused too (tab, paren)"
for bad_repo in "o/r)is:open" "$(printf 'o/r\tis:closed')" "o/r/r" "o/" "/r"; do
  OUT="$(PATH="$WORK/bin:$PATH" FIXTURE_DIR="$WORK/fx" POSTS_FILE="$WORK/posts" HOME="$WORK" \
        /bin/bash "$SCRIPT" --repo "$bad_repo" 2>&1)"; RC=$?
  eq "--repo '$bad_repo' exit" "$RC" 64
done

echo "(l3) ⛔ a --repo that is not owner/name is refused"
: >"$WORK/posts"
OUT="$(PATH="$WORK/bin:$PATH" FIXTURE_DIR="$WORK/fx" POSTS_FILE="$WORK/posts" HOME="$WORK" \
      /bin/bash "$SCRIPT" --repo justaname 2>&1)"; RC=$?
eq "--repo shape exit" "$RC" 64

echo; echo "(m) a failed cancel POST is exit 1 and names the run"
fixture "o/r:feat/dead:www999" "1300 feat/dead www000 3600"
: >"$WORK/fx/cancel.fail"
run --apply
eq "exit (POST failed)" "$RC" 1
has "cancel FAILED 1300" && ok "names the run" || bad "did not name the run"

echo; echo "(n) --help renders help, not the shebang and not the tail of the script"
: >"$WORK/posts"
OUT="$(PATH="$WORK/bin:$PATH" FIXTURE_DIR="$WORK/fx" POSTS_FILE="$WORK/posts" HOME="$WORK" \
      /bin/bash "$SCRIPT" --help 2>&1)"; RC=$?
eq "help exit" "$RC" 0
case "$OUT" in *'!/usr/bin/env'*) bad "shebang leaked into help" ;; *) ok "shebang not in help" ;; esac
case "$OUT" in *'set -uo pipefail'*|*'exec /bin/bash'*) bad "tail of the script leaked into help" ;; *) ok "tail not in help" ;; esac

echo
printf 'ci-queue-hygiene suite: %d assertions passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
