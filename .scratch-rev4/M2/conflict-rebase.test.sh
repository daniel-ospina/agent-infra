#!/usr/bin/env bash
# conflict-rebase.test.sh — suite for scripts/conflict-rebase.py (+ the timer's contract).
#
# Real git, fake `gh`. The bot's whole safety claim is about what it does to a
# BRANCH, so the fixtures are real repositories: a bare "origin", a seed clone, and
# branches whose rebase outcome is a fact of the object database rather than a
# comment in a test. `gh` is stubbed (house convention: see record-review.test.sh)
# so the suite never touches the network or a real PR.
#
# Coverage — each case is a property the brief names:
#   §1  a clean rebase is made and PUSHED, main's change is in the result          (before/after)
#   §2  a CONTENT conflict is REFUSED: labelled, commented, branch UNTOUCHED       (the deliverable)
#   §3  the record is bound to a head: kept when the diff is unchanged, moved
#       aside when it changed, review-asserting labels removed                     (record integrity)
#   §4  a head that does not match the PR's own head is refused, nothing pushed    (peer-pushing)
#   §5  draft / deny-listed / already-labelled / backed-off PRs are never touched
#   §6  --max caps the pass and nothing is rebased twice
#   §7  --dry-run pushes nothing, comments nothing, labels nothing
#   §8  a failed read is exit 2, never "nothing to do"
#   §9  the BEHIND arm is OFF by default and only takes green+recorded PRs
#
# Run: bash scripts/conflict-rebase.test.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOT="$HERE/conflict-rebase.py"
[ -f "$BOT" ] || { echo "❌ cannot find $BOT"; exit 1; }

PASS=0 FAIL=0
ok()   { PASS=$((PASS + 1)); printf '  ✅ %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  ❌ %s\n' "$1"; [ -n "${2:-}" ] && printf '     %s\n' "$2"; }
ck()   { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected '$2', got '$1'"; fi; }
ckn()  { if [ "$1" != "$2" ]; then ok "$3"; else bad "$3" "expected NOT '$2'"; fi; }
# ⛔ NO PIPE HERE. `printf … | grep -qF` fails intermittently in this fleet: `-q`
# exits at the first match, the writer takes SIGPIPE, and the status that surfaces
# depends on scheduling — measured as three FALSE failures in one run (§1/§2/§4)
# with the haystack plainly containing the needle. Plain bash matching has no pipe
# and no early exit, so it cannot flake.
has()  { case "$1" in *"$2"*) ok "$3" ;; *) bad "$3" "missing: $2 | in: $(printf '%s' "$1" | head -c 200 | tr '\n' ' ')" ;; esac; }

TMP="$(mktemp -d /tmp/cr-suite-XXXXXX)"
KEEP=0
cleanup() { [ "$KEEP" = 1 ] || rm -rf "$TMP"; }
trap cleanup EXIT

export GIT_AUTHOR_NAME="suite" GIT_AUTHOR_EMAIL="suite@example.com"
export GIT_COMMITTER_NAME="suite" GIT_COMMITTER_EMAIL="suite@example.com"
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch main
git config --file "$GIT_CONFIG_GLOBAL" user.name suite
git config --file "$GIT_CONFIG_GLOBAL" user.email suite@example.com
git config --file "$GIT_CONFIG_GLOBAL" commit.gpgsign false

REPO="acme/widgets"

# ── fixture: an origin with main and two feature branches ────────────────────
seed_fixture() {
  rm -rf "$TMP/origin.git" "$TMP/seed" "$TMP/state" "$TMP/reviews" "$TMP/fake"
  git init -q --bare "$TMP/origin.git"
  git init -q "$TMP/seed"
  (
    cd "$TMP/seed" || exit 1
    printf 'alpha\nbeta\ngamma\n' > a.txt
    printf 'one\ntwo\nthree\n' > b.txt
    printf 'red\ngreen\nblue\n' > c.txt
    git add a.txt b.txt c.txt && git commit -qm base && git branch -M main
    # `feat/clean` touches b.txt only; main will move a.txt and c.txt.
    git switch -q -c feat/clean && printf 'one\ntwo\nTHREE-clean\n' > b.txt
    git commit -qam "clean: change b's third line"
    # `feat/conflict` and main both rewrite c.txt's SECOND line: a real content conflict.
    git switch -q main && git switch -q -c feat/conflict && printf 'red\nGREEN-conflict\nblue\n' > c.txt
    git commit -qam "conflict: change c's second line"
    git switch -q main && printf 'ALPHA\nbeta\ngamma\n' > a.txt && printf 'red\nGREEN-main\nblue\n' > c.txt && git commit -qam "main moves a.txt and c's second line"
    git remote add origin "$TMP/origin.git"
    git push -q origin main feat/clean feat/conflict
  )
  mkdir -p "$TMP/state" "$TMP/reviews" "$TMP/fake"
  export CONFLICT_REBASE_STATE="$TMP/state"
  export CONFLICT_REBASE_REVIEWS="$TMP/reviews"
  export CONFLICT_REBASE_ORIGIN="$TMP/origin.git"
  export CONFLICT_REBASE_FLEET_STATE="$TMP/no-fleet.json"
  export CONFLICT_REBASE_RECORD_SH="$TMP/fake/record-review.sh"
  export FAKE_ORIGIN="$TMP/origin.git"
  export GH_REPO=""
  # default: diff hash "unchanged" across the rebase
  # ⛔ A `printf '<format>'` SEAM CANNOT CARRY A FORMAT: the OUTER printf consumes the
  # inner `%s` placeholders too, and an empty first argument silently produced
  # `printf "ok\t\n"` — a stub whose hash was always empty. So the path travels in
  # an env var and the stub's own format is written verbatim by a quoted heredoc.
  cat >"$CONFLICT_REBASE_RECORD_SH" <<'EOS'
#!/usr/bin/env bash
printf 'ok\t%s\n' "$(cat "$FAKE_DIFFHASH")"
EOS
  chmod +x "$CONFLICT_REBASE_RECORD_SH"
  export FAKE_DIFFHASH="$TMP/diffhash"
  printf 'aaaa1111\n' >"$FAKE_DIFFHASH"
  chmod +x "$CONFLICT_REBASE_RECORD_SH"
  write_prs '[]'
}

# ── fake gh ─────────────────────────────────────────────────────────────────
write_prs() {  # write_prs '<json array>'  → the fixture the fake gh serves
  printf '%s' "$1" >"$TMP/fake/prs.json"
  cat >"$TMP/fake/gh" <<'EOS'
#!/usr/bin/env bash
# fake gh: serves $FAKE_DIR/prs.json for reads, records writes under $FAKE_DIR.
D="$(dirname "$0")"
cmd="${1:-}"; shift || true
case "$cmd" in
  pr)
    sub="${1:-}"; shift || true
    case "$sub" in
      list)  cat "$D/prs.json" ;;
      view)
        n="${1:-}"; shift || true
        jq_fields=""; while [ $# -gt 0 ]; do case "$1" in --json) jq_fields="$2"; shift 2;; --repo) shift 2;; *) shift;; esac; done
        python3 - "$D/prs.json" "$n" "$jq_fields" <<'PY'
import json, os, subprocess, sys
prs = json.load(open(sys.argv[1])); n = int(sys.argv[2]); fields = sys.argv[3].split(",")
p = next((x for x in prs if int(x["number"]) == n), {})
out = {f: p.get(f) for f in fields}
if "labels" in fields: out["labels"] = p.get("labels") or []
if "mergeable" in fields: out["mergeable"] = "MERGEABLE"
# ⛔ headRefOid MUST BE LIVE. The bot refuses to claim anything about a head it
# cannot see, so a fake that keeps serving the PRE-push sha makes the bot
# correct and the assertion wrong. Read the branch's real tip from the fixture origin.
if "headRefOid" in fields:
    origin = os.environ.get("FAKE_ORIGIN", "")
    br = p.get("headRefName")
    if origin and br:
        r = subprocess.run(["git", "-C", origin, "rev-parse", "refs/heads/" + br],
                           capture_output=True, text=True)
        if r.returncode == 0 and r.stdout.strip():
            out["headRefOid"] = r.stdout.strip()
print(json.dumps(out))
PY
        ;;
      comment)
        n="${1:-}"; shift || true
        body=""; while [ $# -gt 0 ]; do case "$1" in --body-file) body="$2"; shift 2;; *) shift;; esac; done
        cp "$body" "$D/comment-$n.md"; printf '%s\n' "$n" >>"$D/comments.txt" ;;
      edit)
        n="${1:-}"; shift || true
        add=""; rem=""; while [ $# -gt 0 ]; do case "$1" in --add-label) add="$2"; shift 2;; --remove-label) rem="$2"; shift 2;; *) shift;; esac; done
        [ -n "$add" ] && printf '%s ADD %s\n' "$n" "$add" >>"$D/labels.txt"
        [ -n "$rem" ] && printf '%s REMOVE %s\n' "$n" "$rem" >>"$D/labels.txt"
        # ⛔ THE HANDLER MUST END SUCCESSFUL. A trailing `[ -n "$x" ] && …` whose test
        # fails is the branch's exit status, so `gh pr edit --add-label` exited 1 and the
        # bot's (correct) `check=True` read that as an UNREADABLE label surface.
        exit 0 ;;
      *) : ;;
    esac ;;
  label) : ;;
  api)
    # `gh api repos/<o>/<r>/branches/main/protection --jq …` → the required contexts
    if [ -n "${FAKE_API_FAIL:-}" ]; then echo "api boom" >&2; exit 1; fi
    printf '["pipeline-compliance"]\n' ;;
  *) : ;;
esac
EOS
  chmod +x "$TMP/fake/gh"
  rm -f "$TMP/fake/comments.txt" "$TMP/fake/labels.txt" "$TMP/fake/comment-"*.md
}

run_bot() {
  PATH="$TMP/fake:$PATH" python3 "$BOT" --repo "$REPO" "$@" 2>"$TMP/bot.err"
}

head_of() { git -C "$TMP/origin.git" rev-parse "refs/heads/$1"; }

now_iso() { date -u -d '1 hour ago' '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u '+%Y-%m-%dT%H:%M:%SZ'; }
OLD="$(now_iso)"

pr_json() {  # pr_json <num> <branch> <sha> <mergeable> <state> <labels-json> [draft] [green] [updatedAt] [base] [fork]
  python3 - "$1" "$2" "$3" "$4" "${5:-CLEAN}" "${6:-[]}" "${7:-false}" "${8:-false}" "${9:-$OLD}" "${10:-main}" "${11:-false}" <<'PY'
import json, sys
n, br, sha, mg, ms, labels, draft, green, upd, base, fork = sys.argv[1:12]
roll = [{"name": "pipeline-compliance", "conclusion": "SUCCESS"}] if green == "true" else []
print(json.dumps({"number": int(n), "headRefName": br, "headRefOid": sha, "mergeable": mg,
                  "mergeStateStatus": ms, "isDraft": draft == "true", "updatedAt": upd,
                  "isCrossRepository": fork == "true",
                  "headRepository": {"nameWithOwner": "someone/else" if fork == "true" else "acme/widgets"},
                  "labels": json.loads(labels), "title": br, "baseRefName": base,
                  "statusCheckRollup": roll}))
PY
}

# ═══════════════════════ §1 + §2 + §3 + §6: a real pass ═══════════════════════
echo "§1/§2 a clean rebase lands; a content conflict is refused and left alone"
seed_fixture
CLEAN_SHA="$(head_of feat/clean)"; CONF_SHA="$(head_of feat/conflict)"; OLD_MAIN="$(head_of main)"
LBL_REVIEWED='[{"name":"reviewed"}]'
write_prs "[$(pr_json 101 feat/clean "$CLEAN_SHA" CONFLICTING CLEAN "$LBL_REVIEWED"),$(pr_json 102 feat/conflict "$CONF_SHA" CONFLICTING DIRTY)]"
# a record bound to 101's head, AND a review-asserting label
printf '{"head_sha":"%s","verdict":"clean","diff_sha256":"aaaa1111"}\n' "$CLEAN_SHA" >"$TMP/reviews/acme-widgets-101.json"
printf '{"head_sha":"%s","verdict":"clean","diff_sha256":"bbbb2222"}\n' "$CONF_SHA" >"$TMP/reviews/acme-widgets-102.json"

run_bot --max 3 --interval-s 0; RC=$?
[ -n "${CR_DEBUG:-}" ] && { echo "--- debug1 ---"; cat "$TMP/bot.err"; echo "--- /debug1 ---"; }
ck "$RC" "0" "a pass exits 0"

NEW_CLEAN="$(head_of feat/clean)"
ckn "$NEW_CLEAN" "$CLEAN_SHA" "§1 the clean branch was REBASED (head moved)"
# ⛔ NO `<ref>:<path>` FORM ANYWHERE IN THIS SUITE. The checkout guard classifies
# `git show <ref>:<path>` as a working-tree discard ("cat-file-revert") and fails
# closed on a script it cannot resolve — a false positive that made this suite
# unrunnable from the lane it ships from. `git grep <rev> -- <path>` reads the same
# content with no path-restore shape.
has "$(git -C "$TMP/origin.git" grep -c ALPHA feat/clean -- a.txt)" "1" "§1 the rebased branch carries main's change exactly once (no duplicated hunk)"
ck "$(git -C "$TMP/origin.git" grep -c THREE-clean feat/clean -- b.txt)" "feat/clean:b.txt:1" "§1 the branch's own change survived the rebase"
ck "$(git -C "$TMP/origin.git" merge-base --is-ancestor "$OLD_MAIN" feat/clean; echo $?)" "0" "§1 the rebased head is descended from main's tip"

ck "$(head_of feat/conflict)" "$CONF_SHA" "§2 the content-conflicting branch was NOT pushed"
has "$(cat "$TMP/fake/labels.txt" 2>/dev/null)" "102 ADD needs-human-conflict" "§2 the refusal labelled the PR"
has "$(cat "$TMP/fake/comment-102.md" 2>/dev/null || echo)" "needs-human-conflict" "§2 the refusal commented on the PR"
has "$(cat "$TMP/fake/comment-102.md" 2>/dev/null || echo)" "nothing was pushed" "§2 the comment states nothing was pushed"
ckn "$(cat "$TMP/fake/comment-101.md" 2>/dev/null)" "" "§2b the refused PR's comment is not empty"
has "$(cat "$TMP/fake/comment-102.md" 2>/dev/null || echo)" "REFUSED" "§2b the refused PR's comment is the REFUSAL body, not a success body"

has "$(cat "$TMP/fake/comment-101.md" 2>/dev/null || echo)" "$NEW_CLEAN" "§3 the success comment states the NEW head"
has "$(cat "$TMP/fake/comment-101.md" 2>/dev/null || echo)" "byte-identical" "§3 the comment says the reviewed diff is byte-identical (the record carries)"
ck "$([ -f "$TMP/reviews/acme-widgets-101.json" ] && echo present || echo absent)" "present" "§3 a record whose diff is unchanged is KEPT"
has "$(cat "$TMP/fake/labels.txt" 2>/dev/null || echo)" "101 REMOVE reviewed" "§3 a review-asserting label is removed"

# §3b the diff CHANGED => the record must not survive at the canonical path
seed_fixture
CLEAN_SHA="$(head_of feat/clean)"
write_prs "[$(pr_json 201 feat/clean "$CLEAN_SHA" CONFLICTING CLEAN)]"
printf '{"head_sha":"%s","verdict":"clean","diff_sha256":"cccc3333"}\n' "$CLEAN_SHA" >"$TMP/reviews/acme-widgets-201.json"
printf 'dddd4444\n' >"$FAKE_DIFFHASH"
run_bot --max 1 --interval-s 0
ck "$([ -f "$TMP/reviews/acme-widgets-201.json" ] && echo present || echo absent)" "absent" "§3b a record bound to a CHANGED diff is moved off the canonical path"
ck "$(ls "$TMP/reviews" | grep -c 'superseded')" "1" "§3b …and kept for audit as .superseded-<head>"
has "$(cat "$TMP/fake/comment-201.md" 2>/dev/null || echo)" "Re-review is required" "§3b the comment demands the re-review it now needs"

# §3c the diff could not be READ at all => "relation UNKNOWN", never "a DIFFERENT diff"
# (#2698 review, cycle 2, P2). The arm is correct today, but what it guards is a one-line
# `elif` ORDER: `superseded-unverified` starts with `superseded`, so a tidy that moves the
# generic arm up silently restores a comment claiming the diff CHANGED when it was never
# read — a false claim in the one artifact the PR's owner reads. This test pins the order.
seed_fixture
CLEAN_SHA="$(head_of feat/clean)"
write_prs "[$(pr_json 301 feat/clean "$CLEAN_SHA" CONFLICTING CLEAN)]"
printf '{"head_sha":"%s","verdict":"clean","diff_sha256":"eeee5555"}\n' "$CLEAN_SHA" >"$TMP/reviews/acme-widgets-301.json"
# a --print-diff-hash stub that FAILS: diff_hash -> ("unavailable", "")
cat >"$CONFLICT_REBASE_RECORD_SH" <<EOS
#!/usr/bin/env bash
exit 1
EOS
chmod +x "$CONFLICT_REBASE_RECORD_SH"
run_bot --max 1 --interval-s 0 >/dev/null
BODY="$(cat "$TMP/fake/comment-301.md" 2>/dev/null || echo)"
has "$BODY" "**could not be read**" "§3c an unreadable diff is reported as unreadable"
has "$BODY" "Treat this head as UNREVIEWED" "§3c …and its relation to the record as UNKNOWN"
ck "$(case "$BODY" in *"DIFFERENT diff"*) echo claimed-changed ;; *) echo honest ;; esac)" "honest" "§3c …and NEVER as a changed diff (the arm-order trap)"
# ⛔ THE ASSERTIONS ABOVE MUST TARGET THE ARM'S PROSE, NOT `record_state`'s RETURN STRING
# (#2698 review, cycle 3, P2). `_success_body` always echoes `**Review record**: {rec}.`,
# and that machine string contains "could not be read" — so a bare substring check passed
# under the exact mutation it was named for. `**could not be read**` and "Treat this head
# as UNREVIEWED" exist ONLY in the unverified arm's prose; verified by moving the generic
# `elif` above it (then these two go red and the rename assertion stays green).
ck "$(ls "$TMP/reviews" | grep -c 'superseded')" "1" "§3c …and the record was still moved aside (no attestation over an unverified head)"

# ═══════════════════════ §4: peer-pushing ═════════════════════════════════════
echo "§4 a head that is not the PR's own head is refused"
seed_fixture
CLEAN_SHA="$(head_of feat/clean)"
write_prs "[$(pr_json 301 feat/clean 0000000000000000000000000000000000000000 CONFLICTING CLEAN)]"
run_bot --max 1 --interval-s 0
ck "$(head_of feat/clean)" "$CLEAN_SHA" "§4 nothing was pushed"
[ -n "${CR_DEBUG:-}" ] && { echo "--- debug4 ---"; cat "$TMP/bot.err"; echo "--- /debug4 ---"; }
has "$(cat "$TMP/bot.err")" "head-moved" "§4 the refusal names the reason"

# ═══════════════════════ §5/§9: the filters ══════════════════════════════════
echo "§5 draft / deny / labelled / backoff / not-behind are all skipped"
seed_fixture
D_SHA="$(head_of feat/clean)"
write_prs "[$(pr_json 401 feat/clean "$D_SHA" CONFLICTING CLEAN '[]' true),$(pr_json 2172 feat/clean "$D_SHA" CONFLICTING CLEAN),$(pr_json 403 feat/clean "$D_SHA" CONFLICTING CLEAN '[{"name":"needs-human-conflict"}]'),$(pr_json 404 feat/clean "$D_SHA" MERGEABLE BEHIND),$(pr_json 405 feat/clean "$D_SHA" CONFLICTING CLEAN)]"
echo "{\"next_at\": $(( $(date +%s) + 3600 ))}" >"$TMP/state/backoff-405.json"
OUT="$(run_bot --dry-run --max 3 --interval-s 0 --json)"
ck "$(head_of feat/clean)" "$D_SHA" "§5 no branch was touched"
has "$OUT" '"why": "draft"' "§5 a draft is skipped"
has "$OUT" '"why": "deny-list"' "§5 a deny-listed PR is skipped"
has "$OUT" '"why": "labelled needs-human-conflict' "§5 an already-refused PR is skipped"
has "$OUT" '"why": "backoff"' "§5 a backed-off PR is skipped"
has "$OUT" '"why": "mergeable=MERGEABLE"' "§9 a BEHIND PR is not in the CONFLICTING class"

# §9 the BEHIND arm, off by default, on when asked and only for green+recorded
seed_fixture
B_SHA="$(head_of feat/clean)"
printf '{"head_sha":"%s","verdict":"clean","diff_sha256":"aaaa1111"}\n' "$B_SHA" >"$TMP/reviews/acme-widgets-501.json"
write_prs "[$(pr_json 501 feat/clean "$B_SHA" MERGEABLE BEHIND '[]' false true),$(pr_json 502 feat/conflict "$(head_of feat/conflict)" MERGEABLE BEHIND '[]' false true)]"
run_bot --max 2 --interval-s 0
ck "$(head_of feat/clean)" "$B_SHA" "§9 --include-behind is OFF by default"
OUT="$(run_bot --max 2 --interval-s 0 --include-behind --json)"
ckn "$(head_of feat/clean)" "$B_SHA" "§9 with --include-behind a green+recorded PR is rebased"
ck "$(grep -c 'Re-review is required' "$TMP/fake/comment-501.md" 2>/dev/null | head -1)" "0" "§9 the success comment is not a refusal"

# ═══════════════════════ §11: the HOLD check ════════════════════════════════
# Two independent holds, both verified against real git state: a worktree the lane
# created for THIS PR (the sibling conflict lane's `/tmp/rcwt/<PR>` pattern — and a
# detached worktree has NO branch, so a branch-only test saw it as free), and a
# `refs/claims/*` ref (the fleet's designed cross-box CAS).
echo "§11 a PR held by a worktree or a claim ref is never touched"
seed_fixture
H_SHA="$(head_of feat/clean)"
mkdir -p "$TMP/holds"
git -C "$TMP/seed" worktree add -q --detach "$TMP/holds/601" "$H_SHA" 2>/dev/null || true
write_prs "[$(pr_json 601 feat/clean "$H_SHA" CONFLICTING CLEAN)]"
# ⛔ NOT A DRY RUN. With --dry-run the "nothing was touched" assertion cannot fail
# even if the hold check were deleted entirely — the real coverage is that the run
# touched nothing while it WOULD have rebased this branch.
run_bot --max 1 --interval-s 0 --checkout "$TMP/seed" --json >/dev/null
ck "$(head_of feat/clean)" "$H_SHA" "§11a a PR with a PR-named worktree is not touched"
OUT="$(run_bot --dry-run --max 1 --interval-s 0 --checkout "$TMP/seed" --json)"
has "$OUT" 'live lane' "§11b the skip names the live lane"

seed_fixture
H_SHA="$(head_of feat/clean)"
git -C "$TMP/seed" push -q origin "$H_SHA:refs/claims/pr-602" 2>/dev/null || true
write_prs "[$(pr_json 602 feat/clean "$H_SHA" CONFLICTING CLEAN)]"
OUT="$(run_bot --dry-run --max 1 --interval-s 0 --json)"
ck "$(head_of feat/clean)" "$H_SHA" "§11c a PR held in the claim registry is not touched"
has "$OUT" 'claim registry' "§11d the skip names the claim"

# ═══════════════════════ §12: the age and base guards ════════════════════════
# Measured live: a 20-second-old head and a PR targeting `release-1.x` were both
# SELECTED and force-pushed, because a `CONFLICTING` PR took the class arm straight
# past these checks. Both must now be skipped in BOTH arms.
echo "§12 a too-young head and a non-main base are skipped"
seed_fixture
X_SHA="$(head_of feat/clean)"
NOW_ISO="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
write_prs "[$(pr_json 801 feat/clean "$X_SHA" CONFLICTING CLEAN '[]' false false "$NOW_ISO"),$(pr_json 802 feat/clean "$X_SHA" CONFLICTING CLEAN '[]' false false "$OLD" "release-1.x")]"
OUT="$(run_bot --dry-run --max 3 --interval-s 0 --json)"
ck "$(head_of feat/clean)" "$X_SHA" "§12a nothing was touched"
has "$OUT" '"why": "head younger than 15m' "§12b a head younger than the floor is skipped"
has "$OUT" '"why": "base release-1.x (not main)"' "§12c a non-main base is skipped"

# ═══════════════════════ §6: the cap ═════════════════════════════════════════
echo "§6 --max caps a pass"
seed_fixture
A_SHA="$(head_of feat/clean)"; B_SHA2="$(head_of feat/conflict)"
write_prs "[$(pr_json 601 feat/clean "$A_SHA" CONFLICTING CLEAN),$(pr_json 602 feat/conflict "$B_SHA2" CONFLICTING CLEAN)]"
# 602 will refuse (content conflict), so cap the pass at 1 and assert 602 never ran
run_bot --max 1 --interval-s 0
ck "$(head_of feat/conflict)" "$B_SHA2" "§6a the second PR was never reached (cap 1)"
ckn "$(head_of feat/clean)" "$A_SHA" "§6b the first PR was rebased"
# ⛔ THE HEAD TEST ABOVE CANNOT FAIL: 602 is a CONTENT conflict, so its head would be
# unchanged even if the cap were removed. The cap's real property is that no SIDE
# EFFECT reached it — that is what a 36-PR label storm looks like.
ck "$([ -f "$TMP/fake/comment-602.md" ] && echo present || echo absent)" "absent" "§6c the capped-out PR got no comment (the cap bounds ATTEMPTS)"
ck "$([ -f "$TMP/fake/labels.txt" ] && echo present || echo absent)" "absent" "§6d the capped-out PR got no label"

# ═══════════════════════ §7: dry run ═════════════════════════════════════════
echo "§7 --dry-run touches nothing"
seed_fixture
C_SHA="$(head_of feat/clean)"; F_SHA="$(head_of feat/conflict)"
write_prs "[$(pr_json 701 feat/clean "$C_SHA" CONFLICTING CLEAN),$(pr_json 702 feat/conflict "$F_SHA" CONFLICTING CLEAN)]"
OUT="$(run_bot --dry-run --max 3 --interval-s 0 --json)"
ck "$(head_of feat/clean)" "$C_SHA" "§7a dry run pushed nothing"
ck "$(head_of feat/conflict)" "$F_SHA" "§7b dry run pushed nothing on the conflicting one"
ck "$([ -f "$TMP/fake/comments.txt" ] && echo yes || echo no)" "no" "§7c dry run commented nothing"
ck "$([ -f "$TMP/fake/labels.txt" ] && echo yes || echo no)" "no" "§7d dry run labelled nothing"
has "$OUT" '"action": "would-rebase"' "§7e the dry run still REPORTS what it would do"
has "$OUT" '"kind": "content-conflict"' "§7f the dry run still classifies the refusal"

# ═══════════════════════ §8: a failed read is not "nothing to do" ════════════
echo "§8 an unreadable surface is exit 2, never a clean pass"
seed_fixture
cat >"$TMP/fake/gh" <<'EOS'
#!/usr/bin/env bash
echo "boom" >&2; exit 1
EOS
chmod +x "$TMP/fake/gh"
run_bot --max 1 --interval-s 0; RC=$?
ck "$RC" "2" "§8 exit 2 when the PR list cannot be read"
has "$(cat "$TMP/bot.err")" "UNREADABLE" "§8 the log says UNREADABLE, not 'nothing to do'"

# ═══════════════════════ §13: records that are not this repo's ═══════════════
# The legacy `<pr>.json` name is shared across repos (#426). Acting on another repo's
# record would either rename their attestation or claim it attests this PR.
echo "§13 a foreign record is neither renamed nor claimed"
seed_fixture
F_SHA="$(head_of feat/clean)"
write_prs "[$(pr_json 901 feat/clean "$F_SHA" CONFLICTING CLEAN)]"
printf '{"head_sha":"%s","verdict":"clean","diff_sha256":"eeee5555","repo":"someone/else"}\n' "$F_SHA" >"$TMP/reviews/901.json"
printf 'dddd4444\n' >"$FAKE_DIFFHASH"
run_bot --max 1 --interval-s 0 >/dev/null
ck "$([ -f "$TMP/reviews/901.json" ] && echo present || echo absent)" "present" "§13 another repo's record is LEFT ALONE (not renamed)"
ck "$(ls "$TMP/reviews" | grep -c superseded)" "0" "§13 …and no .superseded copy was minted from it"

# ═══════════════════════ §8b: an unreadable claim registry ═══════════════════
# The claim registry is the fleet's 'a lane holds this' signal; reading it as empty
# because it could not be read is the one fail-open that licenses a push.
echo "§8b an unreadable claim registry is exit 2"
seed_fixture
CONFLICT_REBASE_ORIGIN="$TMP/does-not-exist.git" run_bot --max 1 --interval-s 0; RC=$?
ck "$RC" "2" "§8b exit 2 when the claim registry cannot be read"
has "$(cat "$TMP/bot.err")" "UNREADABLE claim registry" "§8b the reason names the claim registry"

# ═══════════════════════ §14: the hold shapes that actually occur ══════════
# Every one of these was a real hole: a branch-only board match (most lanes report
# "(detached)"), a worktree named for a workspace rather than a PR number, and a fork
# PR whose branch name also exists in origin.
echo "§14 a detached lane, a non-numeric worktree, and a fork PR are all skipped"
seed_fixture
H_SHA="$(head_of feat/clean)"
cat >"$TMP/fleet.json" <<EOF
{"repo": "$REPO", "generated_at": "2026-10-24T00:00:00+0000",
 "lanes": [{"identity": {"lane": "cell-x", "branch": "(detached)", "head_sha": "$H_SHA"}}]}
EOF
export CONFLICT_REBASE_FLEET_STATE="$TMP/fleet.json"
write_prs "[$(pr_json 1001 feat/clean "$H_SHA" CONFLICTING CLEAN)]"
OUT="$(run_bot --dry-run --max 1 --interval-s 0 --json)"
ck "$(head_of feat/clean)" "$H_SHA" "§14a a detached lane at this head is not touched"
has "$OUT" "sits at this PR's head" "§14b the skip names the detached lane"

seed_fixture
H_SHA="$(head_of feat/clean)"
mkdir -p "$TMP/holds"
git -C "$TMP/seed" worktree add -q --detach "$TMP/holds/ws_a93c7534" "$H_SHA" 2>/dev/null || true
write_prs "[$(pr_json 1002 feat/clean "$H_SHA" CONFLICTING CLEAN)]"
run_bot --max 1 --interval-s 0 --checkout "$TMP/seed" >/dev/null
ck "$(head_of feat/clean)" "$H_SHA" "§14c a worktree at this head is not touched whatever it is named"

seed_fixture
H_SHA="$(head_of feat/clean)"
write_prs "[$(pr_json 1003 feat/clean "$H_SHA" CONFLICTING CLEAN '[]' false false "$OLD" main true)]"
OUT="$(run_bot --dry-run --max 1 --interval-s 0 --json)"
ck "$(head_of feat/clean)" "$H_SHA" "§14d a fork PR's branch is not pushed"
has "$OUT" '"why": "head repo is not' "§14e the skip names the fork"

# ═══════════════════════ §15: the lease is the enforcement ═══════════════════
# The stability window is manners; the lease is what actually refuses. Simulated by
# moving the remote branch in the stub that runs immediately BEFORE the push.
echo "§15 a peer push inside the window fails closed (lease)"
seed_fixture
H_SHA="$(head_of feat/clean)"
PEER="$(head_of feat/conflict)"
cat >"$CONFLICT_REBASE_RECORD_SH" <<EOS
#!/usr/bin/env bash
git -C "$TMP/origin.git" update-ref refs/heads/feat/clean $PEER
printf 'ok\\t%s\\n' "\$(cat \"\$FAKE_DIFFHASH\")"
EOS
chmod +x "$CONFLICT_REBASE_RECORD_SH"
write_prs "[$(pr_json 1101 feat/clean "$H_SHA" CONFLICTING CLEAN)]"
run_bot --max 1 --interval-s 0 >/dev/null
ck "$(head_of feat/clean)" "$PEER" "§15a the peer's push was NOT overwritten"
has "$(cat "$TMP/bot.err")" "lease-refused" "§15b the refusal is the lease"
ck "$([ -f "$TMP/fake/comment-1101.md" ] && echo present || echo absent)" "absent" "§15c no success comment was posted for a push that did not happen"

# ═══════════════════════ §16: the BEHIND arm's two gates ═══════════════════
echo "§16 the BEHIND arm needs green AND a record"
seed_fixture
H_SHA="$(head_of feat/clean)"
write_prs "[$(pr_json 1201 feat/clean "$H_SHA" MERGEABLE BEHIND '[]' false true),$(pr_json 1202 feat/conflict "$(head_of feat/conflict)" MERGEABLE BEHIND '[]' false false)]"
printf '{"head_sha":"%s","verdict":"clean","diff_sha256":"aaaa1111"}\n' "$H_SHA" >"$TMP/reviews/acme-widgets-1201.json"
OUT="$(run_bot --dry-run --max 2 --interval-s 0 --include-behind --json)"
has "$OUT" "behind but not green" "§16a a red BEHIND PR is skipped for being red"
# 1201 is green + recorded; the ONLY reason to skip it would be the head being fresh,
# so assert it is the one that WOULD be rebased.
# ⛔ §16b USED TO BE VACUOUS (#2698 review, P2). `has "$OUT" '"pr": 1201'` matches the
# `skipped` bucket too (`{"pr": <n>, "why": …}`), so it passed with NO record at the
# head — it would have survived inverting `clean_record_at_head`. Assert the ACTED
# bucket: only a `results` row carries a `branch`/`action`, and only the success path
# emits `would-rebase`.
has "$OUT" '"action": "would-rebase"' "§16b the green+recorded BEHIND PR is considered"
has "$OUT" '"branch": "feat/clean"' "§16c …and it is 1201 in the acted bucket, not the skip bucket"

# ═══════════════════════ §18: the newest attempt decides (#2698 review P1) ══════
# A re-run ADDS a check-run; it does not clear the red one. `checks_green` used to
# require EVERY attempt green, so a PR retried once was ineligible forever — the exact
# population the BEHIND arm exists to serve. Fixture: pipeline-compliance has a
# superseded FAILURE and a newer SUCCESS; the PR must be considered.
echo "§18 a retried required context is GREEN when its NEWEST attempt is green"
seed_fixture
H_SHA="$(head_of feat/clean)"
python3 - "$H_SHA" >"$TMP/prs-mixed.json" <<'PY'
import json, sys
sha = sys.argv[1]
roll = [{"name": "pipeline-compliance", "conclusion": "FAILURE", "startedAt": "2026-10-24T10:00:00Z"},
        {"name": "pipeline-compliance", "conclusion": "SUCCESS", "startedAt": "2026-10-24T11:00:00Z"}]
print(json.dumps([{"number": 1301, "headRefName": "feat/clean", "headRefOid": sha,
                   "mergeable": "MERGEABLE", "mergeStateStatus": "BEHIND", "isDraft": False,
                   "updatedAt": "2020-01-01T00:00:00Z", "isCrossRepository": False,
                   "headRepository": {"nameWithOwner": "acme/widgets"}, "labels": [],
                   "title": "feat/clean", "baseRefName": "main", "statusCheckRollup": roll}]))
PY
write_prs "$(cat "$TMP/prs-mixed.json")"
printf '{"head_sha":"%s","verdict":"clean","diff_sha256":"aaaa1111"}\n' "$H_SHA" >"$TMP/reviews/acme-widgets-1301.json"
OUT="$(run_bot --dry-run --max 2 --interval-s 0 --include-behind --json)"
has "$OUT" '"action": "would-rebase"' "§18a a flake-retried PR is considered, not skipped"
has "$OUT" '"branch": "feat/clean"' "§18b …and it is the acted bucket, not a 'not green' skip"
# The inverse: a PR whose NEWEST attempt is red must still be skipped. Without this the
# assertion above would pass on a `checks_green` that always returns True.
python3 - "$H_SHA" >"$TMP/prs-mixed.json" <<'PY'
import json, sys
sha = sys.argv[1]
roll = [{"name": "pipeline-compliance", "conclusion": "SUCCESS", "startedAt": "2026-10-24T10:00:00Z"},
        {"name": "pipeline-compliance", "conclusion": "FAILURE", "startedAt": "2026-10-24T11:00:00Z"}]
print(json.dumps([{"number": 1301, "headRefName": "feat/clean", "headRefOid": sha,
                   "mergeable": "MERGEABLE", "mergeStateStatus": "BEHIND", "isDraft": False,
                   "updatedAt": "2020-01-01T00:00:00Z", "isCrossRepository": False,
                   "headRepository": {"nameWithOwner": "acme/widgets"}, "labels": [],
                   "title": "feat/clean", "baseRefName": "main", "statusCheckRollup": roll}]))
PY
write_prs "$(cat "$TMP/prs-mixed.json")"
OUT="$(run_bot --dry-run --max 2 --interval-s 0 --include-behind --json)"
has "$OUT" 'behind but not green' "§18c a PR whose NEWEST attempt is red is still skipped (the pair is discriminating)"
# ⛔ THE LEGACY-STATUS ARM (#2698 review, cycle 2, P2). `statusCheckRollup` carries
# `startedAt` on CheckRun and NOT on StatusContext, so an ordinal of `startedAt or ""`
# makes the verdict a function of ROLLUP ORDER for that shape — a newer red masked by an
# older green, i.e. a false green that force-pushes a rebase under a red required gate.
# Ambiguity must fail CLOSED: no ordering -> every attempt green, else not green.
python3 - "$H_SHA" >"$TMP/prs-mixed.json" <<'PY'
import json, sys
sha = sys.argv[1]
# Order A: green first, red second, NEITHER timestamped.
roll = [{"context": "pipeline-compliance", "state": "SUCCESS", "targetUrl": "u"},
        {"context": "pipeline-compliance", "state": "FAILURE", "targetUrl": "u"}]
print(json.dumps([{"number": 1301, "headRefName": "feat/clean", "headRefOid": sha,
                   "mergeable": "MERGEABLE", "mergeStateStatus": "BEHIND", "isDraft": False,
                   "updatedAt": "2020-01-01T00:00:00Z", "isCrossRepository": False,
                   "headRepository": {"nameWithOwner": "acme/widgets"}, "labels": [],
                   "title": "feat/clean", "baseRefName": "main", "statusCheckRollup": roll}]))
PY
write_prs "$(cat "$TMP/prs-mixed.json")"
OUT="$(run_bot --dry-run --max 2 --interval-s 0 --include-behind --json)"
has "$OUT" 'behind but not green' "§18d an UNORDERABLE context with any red attempt is not green (§18d+§18e are order-swapped)"
# Order B: the SAME two attempts, reversed. If the verdict is a function of list position
# these two disagree, and one of them is a false green. Both must be red.
python3 - "$H_SHA" >"$TMP/prs-mixed.json" <<'PY'
import json, sys
sha = sys.argv[1]
roll = [{"context": "pipeline-compliance", "state": "FAILURE", "targetUrl": "u"},
        {"context": "pipeline-compliance", "state": "SUCCESS", "targetUrl": "u"}]
print(json.dumps([{"number": 1301, "headRefName": "feat/clean", "headRefOid": sha,
                   "mergeable": "MERGEABLE", "mergeStateStatus": "BEHIND", "isDraft": False,
                   "updatedAt": "2020-01-01T00:00:00Z", "isCrossRepository": False,
                   "headRepository": {"nameWithOwner": "acme/widgets"}, "labels": [],
                   "title": "feat/clean", "baseRefName": "main", "statusCheckRollup": roll}]))
PY
write_prs "$(cat "$TMP/prs-mixed.json")"
OUT="$(run_bot --dry-run --max 2 --interval-s 0 --include-behind --json)"
has "$OUT" 'behind but not green' "§18e …and the order-reversed twin is red too (order cannot decide)"
# Order C: both attempts green and untimestamped -> green, so the pair above is not
# just "legacy shape is always red".
python3 - "$H_SHA" >"$TMP/prs-mixed.json" <<'PY'
import json, sys
sha = sys.argv[1]
roll = [{"context": "pipeline-compliance", "state": "SUCCESS", "targetUrl": "u"},
        {"context": "pipeline-compliance", "state": "SUCCESS", "targetUrl": "u"}]
print(json.dumps([{"number": 1301, "headRefName": "feat/clean", "headRefOid": sha,
                   "mergeable": "MERGEABLE", "mergeStateStatus": "BEHIND", "isDraft": False,
                   "updatedAt": "2020-01-01T00:00:00Z", "isCrossRepository": False,
                   "headRepository": {"nameWithOwner": "acme/widgets"}, "labels": [],
                   "title": "feat/clean", "baseRefName": "main", "statusCheckRollup": roll}]))
PY
write_prs "$(cat "$TMP/prs-mixed.json")"
OUT="$(run_bot --dry-run --max 2 --interval-s 0 --include-behind --json)"
has "$OUT" '"action": "would-rebase"' "§18f an untimestamped context whose attempts ALL agree green is green"
# ⛔ A TIE ON THE NEWEST ATTEMPT IS AMBIGUOUS ONLY WHEN IT DISAGREES (#2698 review,
# cycle 3, P2). The first fix rejected EVERY tie, so SUCCESS+NEUTRAL landing on the same
# second became a FALSE RED: the arm went inert for a green PR and the skip text blamed a
# fixer who did not exist. Pair the two probes so a "reject every tie" regression and an
# "accept every tie" regression each show up.
python3 - "$H_SHA" >"$TMP/prs-mixed.json" <<'PY'
import json, sys
sha = sys.argv[1]
roll = [{"name": "pipeline-compliance", "conclusion": "SUCCESS", "startedAt": "2026-10-24T11:00:00Z"},
        {"name": "pipeline-compliance", "conclusion": "NEUTRAL", "startedAt": "2026-10-24T11:00:00Z"}]
print(json.dumps([{"number": 1301, "headRefName": "feat/clean", "headRefOid": sha,
                   "mergeable": "MERGEABLE", "mergeStateStatus": "BEHIND", "isDraft": False,
                   "updatedAt": "2020-01-01T00:00:00Z", "isCrossRepository": False,
                   "headRepository": {"nameWithOwner": "acme/widgets"}, "labels": [],
                   "title": "feat/clean", "baseRefName": "main", "statusCheckRollup": roll}]))
PY
write_prs "$(cat "$TMP/prs-mixed.json")"
OUT="$(run_bot --dry-run --max 2 --interval-s 0 --include-behind --json)"
has "$OUT" '"action": "would-rebase"' "§18g an all-GREEN tie on the newest stamp is green (not a false red)"
python3 - "$H_SHA" >"$TMP/prs-mixed.json" <<'PY'
import json, sys
sha = sys.argv[1]
roll = [{"name": "pipeline-compliance", "conclusion": "SUCCESS", "startedAt": "2026-10-24T11:00:00Z"},
        {"name": "pipeline-compliance", "conclusion": "FAILURE", "startedAt": "2026-10-24T11:00:00Z"}]
print(json.dumps([{"number": 1301, "headRefName": "feat/clean", "headRefOid": sha,
                   "mergeable": "MERGEABLE", "mergeStateStatus": "BEHIND", "isDraft": False,
                   "updatedAt": "2020-01-01T00:00:00Z", "isCrossRepository": False,
                   "headRepository": {"nameWithOwner": "acme/widgets"}, "labels": [],
                   "title": "feat/clean", "baseRefName": "main", "statusCheckRollup": roll}]))
PY
write_prs "$(cat "$TMP/prs-mixed.json")"
OUT="$(run_bot --dry-run --max 2 --interval-s 0 --include-behind --json)"
has "$OUT" 'behind but not green' "§18h a DISAGREEING tie on the newest stamp is not green"

# ═══════════════════════ §19: the schedule can actually run (#2698 review P1) ═══
# `timeout` is GNU coreutils; a Mac has none. A bare `timeout 1800 python3 …` exited 127
# on every Mac cell while the timer still stamped its beacon, so `status` reported a
# healthy loop over a bot that never executed. Assert the property, not the wording.
echo "§19 the timer bounds the pass with the repo's own helper, never a bare timeout"
TIMER="$(dirname "$BOT")/conflict-rebase-timer.sh"
ck "$(grep -qE '^[[:space:]]*(if[[:space:]]+!?[[:space:]]*)?timeout[[:space:]]+[0-9]' "$TIMER" && echo bare || echo none)" "none" "§19a the timer never calls a bare timeout"
has "$(cat "$TIMER")" 'lib/bounded.sh' "§19b …it sources the one bounded-execution helper"
has "$(cat "$TIMER")" 'tb_timeout 1800' "§19c …and bounds the pass with it"
has "$(cat "$TIMER")" 'last-failure' "§19d …and a failed pass is visible in status"

# ═══════════════════════ §17: board shapes and an unreadable gate ═══════════
# Three arms that a mutation left green: the board's BRANCH match, the board's REPO
# filter, and the required-contexts read under --include-behind.
echo "§17 the board arm and an unreadable required-contexts read"
seed_fixture
H_SHA="$(head_of feat/clean)"
cat >"$TMP/fleet2.json" <<EOF
{"repo": "$REPO", "lanes": [{"identity": {"lane": "cell-y", "branch": "feat/clean", "head_sha": "deadbeefdeadbeef"}}]}
EOF
export CONFLICT_REBASE_FLEET_STATE="$TMP/fleet2.json"
write_prs "[$(pr_json 1301 feat/clean "$H_SHA" CONFLICTING CLEAN)]"
OUT="$(run_bot --dry-run --max 1 --interval-s 0 --json)"
has "$OUT" 'live lane: fleet-state lane cell-y' "§17a a board lane on the BRANCH is a hold"

# a board for ANOTHER repo must be ignored (and reasoned about), not believed
seed_fixture
H_SHA="$(head_of feat/clean)"
cat >"$TMP/fleet3.json" <<EOF
{"repo": "someone/other", "lanes": [{"identity": {"lane": "foreign", "branch": "feat/clean", "head_sha": "$H_SHA"}}]}
EOF
export CONFLICT_REBASE_FLEET_STATE="$TMP/fleet3.json"
write_prs "[$(pr_json 1302 feat/clean "$H_SHA" CONFLICTING CLEAN)]"
OUT="$(run_bot --dry-run --max 1 --interval-s 0 --json)"
has "$(cat "$TMP/bot.err")" "board arm ignored" "§17b a foreign board is named and ignored"
has "$OUT" '"action": "would-rebase"' "§17c …and its lanes do not block this repo's PR"

# --include-behind with an unreadable branch protection => exit 2, never a clean pass
seed_fixture
H_SHA="$(head_of feat/clean)"
write_prs "[$(pr_json 1303 feat/clean "$H_SHA" MERGEABLE BEHIND '[]' false true)]"
FAKE_API_FAIL=1 run_bot --dry-run --max 1 --interval-s 0 --include-behind; RC=$?
ck "$RC" "2" "§17d an unreadable required-contexts read is exit 2"
has "$(cat "$TMP/bot.err")" "UNREADABLE required contexts" "§17e …and says which surface"

# ── summary ─────────────────────────────────────────────────────────────────
printf '\n%s\n' "──────────────────────────────────────────"
printf 'conflict-rebase.test.sh: PASS=%d FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then KEEP=1; printf 'fixtures kept at %s (CR_KEEP=1 to keep on success too)\n' "$TMP"; exit 1; fi
[ "${CR_KEEP:-0}" = 1 ] && KEEP=1 && printf 'fixtures at %s\n' "$TMP"
exit 0
