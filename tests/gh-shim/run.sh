#!/usr/bin/env bash
# tests/gh-shim/run.sh — the ARGV-LEVEL admin-merge guard (#984).
#
# §11 (#1007) pins the PR POSITIONAL: a URL is resolved through the full gate, a branch
# stays refused. The scanner in `extensions/review-enforcer/index.ts` accepts the same
# one URL shape (`extractMergeSelector`) and runs FIRST, so both layers must agree — the
# §11(g) tripwire fails if the TS shape moves without this file being revisited.
#
# The point of this layer is that bash has already finished when it runs. So these
# tests drive the shim through a real SHELL with the obfuscations that defeated the
# string scanner in seven review rounds — `-${V:--}admin=true`, an `xargs`-assembled
# flag, `gh api …/merge` — and assert refusal. They are not asserting that the shim
# parses obfuscation (it never sees any); they are asserting that obfuscation stops
# mattering, which is the whole claim.
#
# Hermetic: a fake `gh` serves every call and records the argv it received.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHIM="$ROOT/scripts/gh-shim/gh"
VERIFY="$ROOT/scripts/verify-admin-merge-evidence.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gh-shim-suite.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
checks=0
failures=0
pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); failures=$((failures + 1)); echo "   ❌ $1"; }

# ⛔ KILL THE WHOLE LADDER, NOT JUST THE LEADER (review of #2295). `kill -9 $p` signals ONE pid and
# SIGKILL does NOT propagate, so on exactly the recursion these cases exist to detect the descendants
# outlive their leader — still holding this suite's two gate slots, which makes every later case burn
# up to AGENT_GH_GATE_ACQUIRE_TIMEOUT before failing open. Reap by the case's own unique temp path
# (present only in the shim processes' argv, never in this script's), and `wait` the leader so the
# suite cannot race ahead of a half-dead process tree. Defined up here because §10(a) needs it too.
bound_then_reap() {  # $1=pid  $2=argv pattern unique to THIS case  $3=sentinel file to mark on hang
  local hung=1
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do
    kill -0 "$1" 2>/dev/null || { hung=0; break; }
    sleep 0.5
  done
  # ⛔ REAP ON EVERY PATH, NOT ONLY ON A HANG (review of #2295). A leader that exits while a
  # descendant lives on is the SAME leak: the orphan still holds this suite's gate slots, so later
  # cases burn up to AGENT_GH_GATE_ACQUIRE_TIMEOUT. The first version returned early in the loop
  # and never reached `pkill` — measured: survivors=1 with a fast-exiting leader.
  kill -9 "$1" 2>/dev/null
  pkill -9 -f "$2" 2>/dev/null
  wait "$1" 2>/dev/null
  [ "$hung" -eq 1 ] && printf 'HUNG' >>"$3"
  return 0
}

HEAD_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HEAD_B="bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
CAPTURED=""

# Fake real-gh: records the argv, and serves `--jq` by running the program against
# the scenario's pr.json — so the verifier's own jq pipeline is exercised for real.
REAL="$TMP/real-gh"
cat > "$REAL" <<'GHEOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${SCEN:?}/calls"
prog=""; prev=""
for x in "$@"; do
  [ "$prev" = "--jq" ] && prog="$x"
  prev="$x"
done
if [ -n "$prog" ]; then jq -r "$prog" "$SCEN/pr.json" 2>/dev/null || true; fi
exit 0
GHEOF
chmod +x "$REAL"
# Exported for the WHOLE suite: without it the shim falls back to the gh on PATH,
# which is the real one — the tests would then read live GitHub state instead of
# the fixture (and silently pass for the wrong reason).
export AGENT_GH_REAL="$REAL"
# The fleet courtesy gate (#1910) runs on EVERY call the shim makes, so the suite gets its
# own state dir (never the operator's `~/.pi/agent/gh-gate`) and no spacing: the pacing
# ARMS in §13 set both knobs themselves, with real timings. Everything else exercises the
# gate's transparent path, which must not add latency to the assertions above.
export AGENT_GH_GATE_DIR="$TMP/gate"
export AGENT_GH_GATE_INTERVAL_MS=0

export SCEN=""
new_scen() {
  SCEN="$TMP/scen-$1"
  rm -rf "$SCEN"; mkdir -p "$SCEN"
  : > "$SCEN/calls"
  printf '{"headRefOid":"%s","comments":[]}' "$HEAD_A" > "$SCEN/pr.json"
}

# A body that satisfies the certifying contract, bound to <head>.
# (#1388) The residual clause is the producer's CURRENT spelling — `blocked by the
# decision: 0` — and the attribution line must state a zero drop count, or the
# zero is not a MEASURED zero and the certificate is not valid. A fixture that
# pinned the retired spelling went stale the day the producer moved (bcbb7df) and
# was one of the reasons six days passed with every suite green; the contract
# itself is now pinned against a real captured body by
# tests/admin-merge-evidence-contract/run.sh.
cert_body() {
  printf '<!-- admin-merge-safety: %s -->\nPR head: %s\ntest lane: python-ci.yml\nmain compared (union of 7 runs of python-ci.yml): a:1\nPR failing: 15 | main failing: 19 | blocked by the decision: 0\nAttribution — FAILED tokens DROPPED by the parser (not test ids, so NEVER in a failing set): PR=0 | main=0.\n' "$1" "$1"
}

# run through the fake real-gh for every invocation (AGENT_GH_REAL is exported).

# ── 1. an admin merge with NO evidence is refused ───────────────────────────
echo "== 1. the shim refuses an unjustified admin merge, at argv level =="
new_scen noevidence
bash "$SHIM" pr merge 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "no evidence → REFUSED (exit $rc)" || fail "an admin merge with no evidence was ALLOWED"
grep -q "REFUSED" "$TMP/err" && pass "the refusal says REFUSED" || fail "no refusal on stderr"
grep -q "pr merge" "$SCEN/calls" && fail "the real gh was invoked — the merge happened" || pass "the real gh was never invoked"

# ── 2. THE ACCEPTANCE: obfuscation stops mattering ──────────────────────────
echo "== 2. obfuscation that defeated the scanner is refused here (#984) =="
new_scen splice
V=""
bash "$SHIM" pr merge 123 -${V:--}admin=true >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "\`-\${V:--}admin=true\` → REFUSED (exit $rc); bash resolved it before the shim ran" \
  || fail "a SPLICED admin flag was ALLOWED — the splice still hides the flag"
grep -q "pr merge" "$SCEN/calls" && fail "the spliced merge reached the real gh" || pass "the real gh was never invoked"

new_scen xargs
printf '%s' --ad | xargs -I{} "$SHIM" pr merge 123 {}min >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "\`xargs\`-assembled \`{}min\` → REFUSED (exit $rc); the parts never co-occur in the text" \
  || fail "an XARGS-ASSEMBLED admin flag was ALLOWED"
grep -q "pr merge" "$SCEN/calls" && fail "the xargs-assembled merge reached the real gh" || pass "the real gh was never invoked"

new_scen apim
bash "$SHIM" api -X PUT repos/o/r/pulls/123/merge >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "\`gh api …/merge\` → REFUSED (exit $rc) — the REST path is the same merge" \
  || fail "the REST merge path was ALLOWED"

new_scen verb
M=merge
bash "$SHIM" pr "$M" 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "a \$VAR-supplied VERB with --admin → REFUSED (exit $rc)" || fail "a variable verb was ALLOWED"

# ── 3. the evidence opens it ────────────────────────────────────────────────
echo "== 3. head-bound evidence is what opens it =="
new_scen good
cert_body "$HEAD_A" > "$TMP/body-good"
jq -n --rawfile b "$TMP/body-good" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
bash "$SHIM" pr merge 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && pass "certifying evidence for the CURRENT head → allowed (exit 0)" || { fail "valid evidence was REFUSED"; sed 's/^/      /' "$TMP/err"; }
grep -q "^pr merge 123 --admin$" "$SCEN/calls" && pass "the real gh received the ORIGINAL argv unchanged" \
  || fail "argv was not passed through intact: $(cat "$SCEN/calls")"

# ...but evidence bound to a DIFFERENT head must not open it: the marker IS the binding.
new_scen stale
jq -n --rawfile b "$TMP/body-good" '{headRefOid:"'"$HEAD_B"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
bash "$SHIM" pr merge 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "evidence for a STALE head → REFUSED (exit $rc) — the head moved" \
  || fail "evidence for another revision was ACCEPTED"
grep -q "pr merge" "$SCEN/calls" && fail "a stale-head merge reached the real gh" || pass "the real gh was never invoked"

# ...and the clauses must hold for the SAME comment, never across two.
new_scen split
jq -n '{headRefOid:"'"$HEAD_A"'",comments:[
  {body:"<!-- admin-merge-safety: '"$HEAD_A"' -->\nPR head: '"$HEAD_A"'"},
  {body:"main compared (union of 7 runs of x): a:1\nPR failing: 1 | main failing: 0 | blocked by the decision: 0\nAttribution — FAILED tokens DROPPED by the parser (not test ids, so NEVER in a failing set): PR=0 | main=0."}]}' > "$SCEN/pr.json"
bash "$SHIM" pr merge 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "a marker in one comment + a verdict in another → REFUSED (exit $rc)" \
  || fail "the contract was satisfied ACROSS two comments — a forgery class"

# ── 4. it does not get in the way ───────────────────────────────────────────
echo "== 4. ordinary gh use is untouched (over-blocking is a failure too) =="
new_scen benign
bash "$SHIM" --version >/dev/null 2>&1; r1=$?
bash "$SHIM" pr view 123 --json headRefOid >/dev/null 2>&1; r2=$?
bash "$SHIM" pr merge 123 --squash >/dev/null 2>&1; r3=$?
bash "$SHIM" pr merge 123 --admin=false >/dev/null 2>&1; r4=$?
[ "$r1" -eq 0 ] && pass "\`gh --version\` passes through" || fail "\`gh --version\` was blocked"
[ "$r2" -eq 0 ] && pass "\`gh pr view\` passes through" || fail "\`gh pr view\` was blocked"
[ "$r3" -eq 0 ] && pass "a NON-admin merge passes through" || fail "a plain \`--squash\` merge was blocked"
[ "$r4" -eq 0 ] && pass "\`--admin=false\` is not a bypass (existing semantics preserved)" || fail "\`--admin=false\` was blocked"

# The declared NEGATIVE class, at the layer that now decides it (#1776): a `gh` command
# that merely MENTIONS `admin` — here with a construct in an unrelated argument — must
# pass through with its argv intact. This is the argv of the command whose false block
# opened #1776; the extension's own stand-down is pinned in its suite, and THIS is the
# layer that then has to deliver an ordinary `gh pr create`.
new_scen mention-negative
bash "$SHIM" pr create --title "fix(admin-merge): x" --body "ask the admin" >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && grep -q '^pr create --title fix(admin-merge): x --body ask the admin$' "$SCEN/calls" \
  && pass "a mention of \`admin\` under a construct passes through, argv intact" \
  || fail "the negative class was gated by the argv layer (rc=$rc): $(head -1 "$TMP/err")"

# ── 5. the audited hatch still works ────────────────────────────────────────
echo "== 5. the operator hatch is preserved, loudly =="
new_scen override
AGENT_ADMIN_MERGE_OVERRIDE=1 bash "$SHIM" pr merge 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && pass "AGENT_ADMIN_MERGE_OVERRIDE=1 → allowed (exit 0)" || fail "the operator hatch no longer works"
grep -q "OVERRIDE" "$TMP/err" && pass "the override is announced on stderr (audited)" || fail "the override is silent"
grep -q "pr merge" "$SCEN/calls" && pass "the merge reached the real gh" || fail "the merge did not reach the real gh"

# ── 6. fail closed when it cannot decide ────────────────────────────────────
echo "== 6. an unresolvable guard fails CLOSED =="
new_scen nopr
bash "$SHIM" pr merge --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "an admin merge with no PR number → REFUSED (exit $rc)" || fail "a PR-less admin merge was allowed"

new_scen noverify
# The verifier is resolved from the SHIM'S OWN location and there is NO env override
# (an earlier `AGENT_GH_SHIM_VERIFY` seam was reachable in PRODUCTION: pointing it at
# /dev/null made the check exit 0 and the merge proceeded unevidenced). A shim copied
# away from its sibling verifier must therefore refuse.
mkdir -p "$TMP/lonely" && cp "$SHIM" "$TMP/lonely/gh"
SCEN="$SCEN" AGENT_GH_REAL="$REAL" bash "$TMP/lonely/gh" pr merge 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "a shim with no sibling verifier → REFUSED (exit $rc)" || fail "a missing verifier allowed the merge"
grep -q "verifier is missing" "$TMP/err" && pass "  …and it says so (not a generic refusal)" || fail "  …but refused for the wrong reason"

# The PRODUCTION wiring passes a NEUTRAL SYMLINK (~/.pi/agent/shims/gh -> here), so
# ${BASH_SOURCE[0]} is the LINK. Resolving the script's own path through symlinks is
# what keeps the verifier findable; without it every admin merge would be refused with
# "verifier is missing" — fail-closed, but the layer would be dead in production.
ln -sf "$SHIM" "$TMP/neutral-gh"
SCEN="$SCEN" AGENT_GH_REAL="$REAL" bash "$TMP/neutral-gh" pr merge 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "invoked through a symlink: still checked (exit $rc)" || fail "through a symlink the merge was allowed"
grep -q "no head-bound evidence" "$TMP/err" \
  && pass "  …and it FOUND its verifier (refused on the evidence, not on the path)" \
  || fail "  …but it could not find the verifier — symlink resolution is broken"

new_scen unreachable
printf '{"headRefOid":"not-a-sha","comments":[]}' > "$SCEN/pr.json"
bash "$SHIM" pr merge 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "an unusable head sha → REFUSED (exit $rc)" || fail "an unusable head was treated as verified"

# ── 7. --repo is forwarded so evidence is read from the MERGED repo ─────────
echo "== 7. --repo reaches the evidence lookup =="
new_scen repo
bash "$SHIM" -R owner/other pr merge 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "a repo-qualified admin merge is still checked (exit $rc)" || fail "the repo-qualified form slipped past"
grep -q -- "--repo owner/other" "$SCEN/calls" && pass "the repo flag reached the verifier's gh call" \
  || fail "--repo was dropped, so evidence would be read from the WRONG repo: $(cat "$SCEN/calls")"

# ── 8. the shapes VGATE cycle 1 found open (fail-open, fixed) ─────────────
echo "== 8. query/fragment endpoints, value-flags, and attached --repo ="

# (a) `gh api …/merge?s=1`/`#x` — gh routes BOTH to the merge endpoint, and the
# token then ends with neither `/merge` nor `/merge/…`, so matching the bare token
# missed it in BOTH layers. The endpoint must be matched with query/fragment stripped.
for suffix in '?s=1' '#x' '?s=1#x'; do
  new_scen "apiquery${suffix//[^a-z0-9]/}"
  bash "$SHIM" api -X PUT "repos/o/r/pulls/123/merge$suffix" >/dev/null 2>"$TMP/err"; rc=$?
  [ "$rc" -ne 0 ] && pass "\`gh api …/merge$suffix\` → REFUSED (exit $rc)" \
    || fail "\`gh api …/merge$suffix\` was ALLOWED — the query hid the merge endpoint"
done

# (b) A VALUE must not be mistaken for the PR positional: gh merges the CURRENT
# BRANCH's PR when the positional is absent, so verifying #123 would check one PR
# and merge another. The certificate below is VALID for #123 — the refusal must come
# from the unresolvable positional, not from missing evidence.
for shape in '--body 123' '-b 123' '--subject 123' '-t 123' '--body-file 123' '-F 123'; do
  new_scen "valflag${shape//[^a-z0-9]/}"
  jq -n --rawfile b "$TMP/body-good" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
  bash "$SHIM" pr merge --admin $shape >/dev/null 2>"$TMP/err"; rc=$?
  [ "$rc" -ne 0 ] && pass "\`gh pr merge --admin $shape\` → REFUSED (exit $rc); the number is a VALUE" \
    || fail "\`--admin $shape\` ALLOWED: verified #123 while merging the current branch's PR"
done
# …and the attached form of a value flag must not be re-read as the positional.
new_scen valflagattached
jq -n --rawfile b "$TMP/body-good" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
bash "$SHIM" pr merge --admin --body=123 >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "\`--body=123\` → REFUSED (exit $rc); attached values consume nothing" \
  || fail "\`--body=123\` was ALLOWED"

# (c) ATTACHED repo forms. gh accepts all three spellings; dropping the repo reads the
# evidence from the WRONG repository — and the wrong repo usually has no evidence, so
# this is the direction that MATTERS: it must be forwarded, not merely tolerated.
for shape in '--repo owner/other' '--repo=owner/other' '-R owner/other' '-Rowner/other'; do
  new_scen "repo${shape//[^a-z0-9]/}"
  bash "$SHIM" pr merge 123 --admin $shape >/dev/null 2>"$TMP/err"; rc=$?
  [ "$rc" -ne 0 ] && pass "\`$shape\` → still checked (exit $rc)" || fail "\`$shape\` slipped past the check"
  grep -q -- "--repo owner/other" "$SCEN/calls" \
    && pass "  …and the repo reached the evidence lookup" \
    || fail "  …but the repo was DROPPED, so evidence was read from the wrong repo"
done

# (d) The verifier's zero clause must not accept a LARGER number beginning with 0.
#     The count line is NON-VACUOUS (PR failing: 1) and the attribution line is
#     present, so the ONLY reason this refuses is the boundary — otherwise the
#     test would pass for the wrong reason (a vacuous body is refused by clause 5
#     whether or not the zero is bounded).
printf '<!-- admin-merge-safety: %s -->\nPR head: %s\nmain compared (union of 1 run of x): a:1\nPR failing: 1 | main failing: 0 | blocked by the decision: 0.5\nAttribution — FAILED tokens DROPPED by the parser (not test ids, so NEVER in a failing set): PR=0 | main=0.\n' "$HEAD_A" "$HEAD_A" > "$TMP/body-half"
bash "$VERIFY" --body-file "$TMP/body-half" --head "$HEAD_A" >/dev/null 2>&1 \
  && fail "\`blocked by the decision: 0.5\` certified — a non-zero residual passed" \
  || pass "\`blocked by the decision: 0.5\` does NOT certify (the zero clause is exact)"

# ── 9. the shapes VGATE cycle 2 found open (fail-open, fixed) ─────────────
echo "== 9. the test seam, endpoint case, GraphQL, and value-flag completeness ="

# (a) The removed test seam must not still work. The signature of the seam is that the
# verifier is NOT RUN, so reproduce it with NO valid evidence: a live seam would let
# /dev/null (which exits 0 for anything) certify the merge, with NO announcement. A
# valid-certificate setup would pass for the wrong reason — the merge is allowed
# because the evidence is real — so this deliberately uses an EMPTY comment list.
new_scen seam
printf '{"headRefOid":"%s","comments":[]}' "$HEAD_A" > "$SCEN/pr.json"
AGENT_GH_SHIM_VERIFY=/dev/null bash "$SHIM" pr merge 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "AGENT_GH_SHIM_VERIFY=/dev/null does NOT bypass (exit $rc)" \
  || fail "the verifier override still silently disables the check"

# (b) GitHub's route matching is case-insensitive: `PUT …/pulls/1/MERGE` reaches the
# merge endpoint (live: 401, where a bogus path is 404), but the glob was case-sensitive.
for variant in 'MERGE' 'Merge' 'meRge'; do
  new_scen "case${variant}"
  bash "$SHIM" api -X PUT "repos/o/r/pulls/123/$variant" >/dev/null 2>"$TMP/err"; rc=$?
  [ "$rc" -ne 0 ] && pass "\`gh api …/pulls/123/$variant\` → REFUSED (exit $rc)" \
    || fail "\`…/$variant\` was ALLOWED — the endpoint matched case-sensitively"
done

# (c) GraphQL needs NO obfuscation, and `mergePullRequest` is the very mutation
# `gh pr merge --admin` issues (gh's REST payload has no admin field).
new_scen graphql
bash "$SHIM" api graphql -f 'query=mutation { mergePullRequest(input:{pullRequestId:"PR_kwDOA"}) { pullRequest { merged } } }' >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "\`gh api graphql … mergePullRequest …\` → REFUSED (exit $rc)" \
  || fail "the GraphQL merge mutation was ALLOWED — an admin-equivalent merge with no evidence"
# …and a genuinely unrelated GraphQL read stays allowed (no over-block).
bash "$SHIM" api graphql -f 'query={ viewableSet { name } }' >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && pass "an unrelated GraphQL READ is passed through (no over-block)" \
  || fail "an unrelated GraphQL read was refused"

# (d) Legitimate shapes must NOT be over-blocked now that the value-flag list is closed.
for shape in '--author-email a@b.c' '-A a@b.c' '-b123' '-Fbody.txt' '-thello' '--'; do
  new_scen "noblock${shape//[^a-z0-9]/}"
  jq -n --rawfile b "$TMP/body-good" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
  bash "$SHIM" pr merge 123 --admin $shape >/dev/null 2>"$TMP/err"; rc=$?
  [ "$rc" -eq 0 ] && pass "\`gh pr merge 123 --admin $shape\` with evidence → allowed" \
    || fail "\`$shape\` was over-blocked: $(head -1 "$TMP/err")"
done

# (e) `-R=owner/other` is valid pflag — the leading `=` is not part of the value.
new_scen repoattached
bash "$SHIM" pr merge 123 --admin -R=owner/other >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "\`-R=owner/other\` → still checked (exit $rc)" || fail "\`-R=…\` slipped past"
grep -q -- "--repo owner/other" "$SCEN/calls" \
  && pass "  …and the value reached the lookup without the stray \`=\`" \
  || fail "  …but the \`=\` corrupted the repo value"

# (f) …and the zero clause must not accept a delimiter that only LOOKS like a number.
for evil in '0,5' '0x' '0/9'; do
  printf '<!-- admin-merge-safety: %s -->\nPR head: %s\nmain compared (union of 1 run of x): a:1\nPR failing: 1 | main failing: 0 | blocked by the decision: %s\nAttribution — FAILED tokens DROPPED by the parser (not test ids, so NEVER in a failing set): PR=0 | main=0.\n' "$HEAD_A" "$HEAD_A" "$evil" > "$TMP/body-evil"
  bash "$VERIFY" --body-file "$TMP/body-evil" --head "$HEAD_A" >/dev/null 2>&1 \
    && fail "\`blocked by the decision: $evil\` certified" \
    || pass "\`blocked by the decision: $evil\` does NOT certify"
done

# ── 10. the shapes VGATE cycle 3 found open (fail-open / hang, fixed) ──────
echo "== 10. self-recursion, file-supplied GraphQL, and attached --hostname ="

# (a) THE PRODUCTION PATH. The harness prepends a NEUTRAL directory holding a SYMLINK
# back to this shim. Skipping only $SELF_DIR meant `-x "$d/gh"` matched the SHIM ITSELF,
# so `REAL` became the shim and `exec "$REAL"` re-entered forever: EVERY gh call hung.
# Exit status alone cannot show this — a hang is not a status — so bound it in time.
mkdir -p "$TMP/neutral" "$TMP/bin"
ln -sf "$SHIM" "$TMP/neutral/gh"
printf '#!/usr/bin/env bash\nprintf "REALGH-CALLED %%s\\n" "$*"\n' > "$TMP/bin/gh"
chmod +x "$TMP/bin/gh"
# ⛔ FILE, NOT A CAPTURE PIPE (review of #2295). This is the case that detects the neutral-symlink
# recursion, and it was in the one shape that CANNOT report it: the ladder's descendants inherit the
# substitution's write end, so after `kill -9 $p` the substitution waits for an EOF that never comes
# and the `*HUNG*` arm below is exactly the arm that cannot fire (reproduced rc=124, no output).
: > "$TMP/a1b.out"
( cd "$TMP" && env -u AGENT_GH_REAL -u SCEN PATH="$TMP/neutral:$TMP/bin:/usr/bin:/bin" \
  bash "$TMP/neutral/gh" pr view 1 ) >>"$TMP/a1b.out" 2>&1 &
p=$!
bound_then_reap "$p" "$TMP/neutral/gh" "$TMP/a1b.out"
out="$(cat "$TMP/a1b.out")"
case "$out" in
  *HUNG*) fail "through the neutral symlink it re-exec'd ITSELF — every gh call would hang" ;;
  "")     fail "through the neutral symlink nothing ran" ;;
  *)      pass "the neutral-symlink path terminates (it does not re-exec itself)" ;;
esac
case "$out" in
  *REALGH-CALLED*) pass "  …and it really reached the real gh, not a fallback" ;;
  *HUNG*) ;;  # already reported
  *) fail "  …but the real gh never ran: $out" ;;
esac

# (a2) THE INHERITED-VALUE SEAM (#2266). `AGENT_GH_REAL` exists so a NESTED call does not
# recurse — but its value is whatever an outer process exported, and it used to be accepted
# on `-x` alone. A launcher that exported it as THIS SCRIPT turned every call into a ladder:
# one generation per `AGENT_GH_GATE_ACQUIRE_TIMEOUT`, each waiting on the slot its own child
# held. Measured 2026-10-21: 2,543 shim processes, load 12.8, every gh call on the box dead
# for ~10 hours. Bound it in time (a hang is not a status) and require the FALL-THROUGH: the
# call must reach the real gh, so refusing the bad value is not enough by itself.
#
# ⛔ THE TIME BOUND NEEDS A FILE, NOT A CAPTURE PIPE (review of #2295). `out="$( … & …)"`
# cannot deliver a verdict on the regression this case exists to catch: the recursion's
# descendants INHERIT the substitution's write end, so after `kill -9 $p` the substitution
# still waits for an EOF that never comes — the case hangs the suite instead of reporting,
# and the in-test bound fires too late to be read (measured: rc=137 from an outer timeout,
# no case output at all). A regular file has no EOF to wait for, so the sentinel is delivered.
: > "$TMP/a2.out"
( cd "$TMP" && env AGENT_GH_REAL="$TMP/neutral/gh" SCEN= PATH="$TMP/neutral:$TMP/bin:/usr/bin:/bin" \
    bash "$TMP/neutral/gh" pr view 1 ) >>"$TMP/a2.out" 2>&1 &
p=$!
bound_then_reap "$p" "$TMP/neutral/gh" "$TMP/a2.out"
out="$(cat "$TMP/a2.out")"
case "$out" in
  *HUNG*) fail "AGENT_GH_REAL=<this shim> re-exec'd ITSELF — a self-recursion ladder, every gh call hangs" ;;
  *REALGH-CALLED*) pass "AGENT_GH_REAL=<this shim> is refused and resolution FALLS THROUGH to the real gh" ;;
  *) fail "AGENT_GH_REAL=<this shim> did not reach the real gh: $out" ;;
esac

# (a3) `-x` IS TRUE FOR A SEARCHABLE DIRECTORY (review of #2295). The env seam accepted the
# inherited value on `-x` alone while the PATH walk has always carried `-f`, so the two halves
# of one decision disagreed: a directory-valued AGENT_GH_REAL was "resolved" and exec'd,
# giving rc 126 "Is a directory" on EVERY gh call. Same file-redirect reasoning as (a2).
mkdir -p "$TMP/ghdir"
: > "$TMP/a3.out"
( cd "$TMP" && env AGENT_GH_REAL="$TMP/ghdir" SCEN= PATH="$TMP/neutral:$TMP/bin:/usr/bin:/bin" \
    bash "$TMP/neutral/gh" pr view 1 ) >>"$TMP/a3.out" 2>&1 &
p=$!
bound_then_reap "$p" "$TMP/neutral/gh" "$TMP/a3.out"
out="$(cat "$TMP/a3.out")"
case "$out" in
  *HUNG*) fail "AGENT_GH_REAL=<a directory> left the shim spinning/hung" ;;
  *REALGH-CALLED*) pass "AGENT_GH_REAL=<a directory> is refused (never exec'd) and resolution FALLS THROUGH to the real gh" ;;
  *) fail "AGENT_GH_REAL=<a directory> did not reach the real gh: $out" ;;
esac

# (a4) THE INHERITED VALUE IS USUALLY A REAL ELF, SO THE READ MUST BE SILENT (#2184/#2305, review
# of #2295). On a delegated call the inherited value IS the genuine gh — a binary full of NUL bytes —
# and `_is_harness_layer` reads it on EVERY call. The form that leaks is a command substitution over
# it: bash >=4.4 then prints `warning: command substitution: ignored null byte in input` onto a call
# that SUCCEEDS, and `gh-rest/gh` parses stderr as JSON (`2>&1 | jq`), so that is a JSONDecodeError on
# every gh call in the tree — #2305 grades exactly this. The assertion is BYTE-CLEAN stderr, which is
# the property itself and is form-agnostic: reverting the helper to `case "$(head -c 8192 …)"` fails
# here (measured 96 stderr bytes on an rc=0 call), while both legitimate outcomes — the value accepted
# as the real gh, or refused and fallen through — must be silent.
ELFGH="$TMP/elfgh-$$"; ELFERR="$TMP/elfgh.err"
if [ -x /bin/true ]; then cp /bin/true "$ELFGH"; else printf '\177ELF\0\0\0\0\0\0\0\0' > "$ELFGH"; fi
chmod +x "$ELFGH"
: > "$ELFERR"
( cd "$TMP" && env AGENT_GH_REAL="$ELFGH" SCEN= PATH="$TMP/neutral:$TMP/bin:/usr/bin:/bin" \
    bash "$TMP/neutral/gh" pr view 1 ) >/dev/null 2>"$ELFERR"
if [ -s "$ELFERR" ]; then
  fail "a binary (ELF) AGENT_GH_REAL leaked $(wc -c <"$ELFERR") bytes onto a SUCCESSFUL call's stderr — gh-rest's 2>&1 parse is a JSONDecodeError (#2184/#2305): $(head -1 "$ELFERR")"
else
  pass "a binary (ELF) AGENT_GH_REAL leaves a successful call's stderr byte-clean (#2184/#2305)"
fi

# (a5) ⛔ AN UNREADABLE CANDIDATE MUST NOT TOUCH A SUCCESSFUL CALL'S STDERR (#2305, review of #2295).
# The marker is read through `< "$1"` inside a process substitution, and a failed open is reported by
# the SHELL, not by `head` — redirections apply LEFT TO RIGHT, so `head -c 8192 < "$1" 2>/dev/null`
# prints `shim: line N: <path>: Permission denied` onto a call that SUCCEEDS. `-f` and `-x` are both
# TRUE for a mode-111 file, so it reaches this read, and the leak is gh-rest's `2>&1 | jq`
# JSONDecodeError — the class this seam was fixed for, reintroduced by moving the open from `head` to
# the shell. (a4) cannot catch it (its fixture is readable). Measured pre-fix: 82 bytes at rc=0.
UNREAD="$TMP/unreadable-gh-$$"; UNREADERR="$TMP/unreadable-gh.err"
if [ -x /bin/true ]; then cp /bin/true "$UNREAD"; else printf '\177ELF\0\0\0\0\0\0\0\0' > "$UNREAD"; fi
chmod 111 "$UNREAD"
: > "$UNREADERR"
( cd "$TMP" && env AGENT_GH_REAL="$UNREAD" SCEN= PATH="$TMP/neutral:$TMP/bin:/usr/bin:/bin" \
    bash "$TMP/neutral/gh" pr view 1 ) >/dev/null 2>"$UNREADERR"
if [ -s "$UNREADERR" ]; then
  fail "an unreadable (mode 111) AGENT_GH_REAL leaked $(wc -c <"$UNREADERR") bytes onto a SUCCESSFUL call's stderr — gh-rest's 2>&1 parse is a JSONDecodeError (#2305): $(head -1 "$UNREADERR")"
elif [ -r "$UNREAD" ]; then
  pass "unreadable-candidate stderr is clean (vacuous as root — uid 0 reads a mode-111 file anyway)"
else
  pass "an unreadable (mode 111) AGENT_GH_REAL leaves a successful call's stderr byte-clean (#2305)"
fi

# (b) A query supplied from a FILE or STDIN cannot be inspected at all — no argv token
# carries `mergePullRequest`. Refuse rather than assume benign.
for shape in '-F query=@/tmp/q.graphql' '-f query=@/tmp/q.graphql' '--input /tmp/body.json' '-F query=@-'; do
  new_scen "gqlfile${shape//[^a-z0-9]/}"
  bash "$SHIM" api graphql $shape >/dev/null 2>"$TMP/err"; rc=$?
  [ "$rc" -ne 0 ] && pass "\`gh api graphql $shape\` → REFUSED (exit $rc)" \
    || fail "\`$shape\` was ALLOWED — an uninspectable GraphQL query"
done

# (c) …while an ordinary REST call that happens to carry an `@` is NOT affected.
new_scen restat
bash "$SHIM" api user -f 'note=me@example.com' >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && pass "a non-graphql \`gh api\` with an \`@\` is passed through (no over-block)" \
  || fail "a non-graphql \`gh api\` was refused"

# (d) The attached form of a global value flag must not read as an unrecognized flag.
new_scen hostnameeq
jq -n --rawfile b "$TMP/body-good" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
bash "$SHIM" pr merge 123 --admin --hostname=github.com >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && pass "\`--hostname=github.com\` with evidence → allowed (no over-block)" \
  || fail "\`--hostname=…\` was over-blocked: $(head -1 "$TMP/err")"
# ── 11. the PR POSITIONAL: a URL is resolved, a branch is refused (#1007) ────
echo "== 11. a PR URL is a second selector — resolved by the SAME gate (#1007) =="
# gh takes a NUMBER, a URL, or a BRANCH in this slot. The gate used to resolve only a
# number, so a URL was refused — fail-closed, but an over-block, and an over-block is
# what pushes a caller at the override hatch. The URL is now resolved; the branch stays
# refused on purpose (resolving one needs a `gh` call, i.e. the gate asking the gated
# thing who it is gating). PARITY: the outer scanner accepts the SAME one URL shape —
# see `test("extractMergeSelector")` in `extensions/review-enforcer/index.test.ts`.
URL="https://github.com/daniel-ospina/agent-infra/pull/1006"
cert_body "$HEAD_A" > "$TMP/body-url"

# (a) The URL resolves to its number, and the URL'S REPO reaches the evidence lookup.
# The number assertion IS the issue's acceptance: what reaches the verifier must be the
# number parsed out of the URL, not a number that merely happened to be nearby.
new_scen urlgood
jq -n --rawfile b "$TMP/body-url" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
bash "$SHIM" pr merge "$URL" --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && pass "a PR URL with head-bound evidence → allowed (exit 0)" \
  || { fail "the URL form was refused"; sed 's/^/      /' "$TMP/err"; }
grep -q "pr view 1006 --repo daniel-ospina/agent-infra --json headRefOid" "$SCEN/calls" \
  && pass "the number extracted from the URL (1006), with the URL's repo, reached the verifier" \
  || fail "the extracted number/repo did not reach the verifier: $(cat "$SCEN/calls")"
grep -q "^pr merge $URL --admin$" "$SCEN/calls" && pass "the real gh received the ORIGINAL argv unchanged" \
  || fail "argv was not passed through intact: $(cat "$SCEN/calls")"

# ...and the flag BEFORE the positional must not hide the URL either (`--admin` is
# value-less, so it consumes nothing — a regression here would refuse a valid call).
new_scen urladminfirst
jq -n --rawfile b "$TMP/body-url" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
bash "$SHIM" pr merge --admin "$URL" >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && pass "\`--admin\` before the URL → still resolved (exit 0)" \
  || { fail "flag order hid the URL"; sed 's/^/      /' "$TMP/err"; }

# (b) TWO-DIRECTION PROOF, direction 1: the URL form routes through the FULL gate, so an
# UNEVIDENCED URL admin merge is refused exactly as a bare number is.
new_scen urlnovidence
bash "$SHIM" pr merge "$URL" --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "an UNEVIDENCED URL admin merge → REFUSED (exit $rc)" \
  || fail "a URL bypassed the evidence gate"
grep -q "pr merge" "$SCEN/calls" && fail "the real gh was invoked — the merge happened" \
  || pass "the real gh was never invoked"

# ...direction 1b: head pinning still BINDS through the URL — a stale marker does not open it.
new_scen urlstale
jq -n --rawfile b "$TMP/body-url" '{headRefOid:"'"$HEAD_B"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
bash "$SHIM" pr merge "$URL" --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && pass "evidence for a STALE head via URL → REFUSED (exit $rc)" \
  || fail "a stale marker opened the URL form"

# (c) gh resolves a PR URL against the URL's OWN repo and IGNORES a contradicting
# --repo (probed live 2026-09-14 — see the shim header). So the evidence must be read
# from the URL's repo, and the ignored flag is announced rather than dropped silently.
new_scen urlrepowins
jq -n --rawfile b "$TMP/body-url" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
bash "$SHIM" pr merge "$URL" --admin --repo owner/other >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && pass "a contradicting --repo does not over-block (gh ignores it; the URL wins)" \
  || { fail "the contradiction was refused instead of resolved to the URL's repo"; sed 's/^/      /' "$TMP/err"; }
grep -q "pr view 1006 --repo daniel-ospina/agent-infra" "$SCEN/calls" \
  && pass "  …and the evidence was read from the URL's repo" \
  || fail "  …but the evidence was read from the wrong repo: $(cat "$SCEN/calls")"
# The real-gh line legitimately carries the original argv (incl. the ignored flag);
# what must not carry it is the EVIDENCE LOOKUP.
if grep "^pr view" "$SCEN/calls" | grep -q -- "--repo owner/other"; then
  fail "  …the contradicting --repo reached the lookup"
else
  pass "  …the contradicting --repo did NOT reach the lookup"
fi
grep -q "ignored" "$TMP/err" && pass "  …and the caller is TOLD the flag was ignored" \
  || fail "  …the ignored flag was silent"

# (d) Every near-miss stays REFUSED — a branch, and the malformed-URL family. Strictness
# is the point: the number is accepted only when it is IN the token.
badsel_n=0
for bad in "my-branch" "release/v2" "feature/1007" \
  "https://github.com/o/r/pull/abc" "https://github.com/o/r/pull/" \
  "https://github.com/o/r/pull/123/files" "https://github.com/o/r/pull/123/" \
  "https://github.com/o/r/pull/123?s=1" "https://github.com/o/r/pull/123#x" \
  "http://github.com/o/r/pull/123" "github.com/o/r/pull/123" \
  "https://evil.com/o/r/pull/123" "https://www.github.com/o/r/pull/123" \
  "https://github.com/o/r" "https://github.com//pull/1" "https://github.com/o//pull/1" \
  "https://github.com/o!/r/pull/1" "https://github.com/o/x y/pull/1" \
  "https://github.com/o/r/pull/0" "https://github.com/o/r/pull/01006" \
  "https://github.com/o/r/pull/9007199254740993"; do
  badsel_n=$((badsel_n + 1))
  new_scen "badsel$badsel_n"
  jq -n --rawfile b "$TMP/body-url" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
  bash "$SHIM" pr merge "$bad" --admin >/dev/null 2>"$TMP/err"; rc=$?
  if [ "$rc" -ne 0 ] && ! grep -q "pr merge" "$SCEN/calls"; then
    pass "\`$bad\` → REFUSED (exit $rc)"
  else
    fail "\`$bad\` was ACCEPTED as a PR selector (rc=$rc)"
  fi
done

# ...and the branch refusal says WHY, so a reader sees a decision rather than a bug.
new_scen urlbranch
bash "$SHIM" pr merge my-branch --admin >/dev/null 2>"$TMP/err"; rc=$?
grep -q "BRANCH name is deliberately NOT resolved" "$TMP/err" \
  && pass "a branch refusal explains that it is deliberate (not a bare 'not a number')" \
  || fail "the branch refusal does not say it is deliberate: $(head -1 "$TMP/err")"

# (e) No over-block on ordinary use: a URL in a NON-admin merge passes through untouched.
new_scen urlsquash
bash "$SHIM" pr merge "$URL" --squash >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && pass "a NON-admin URL merge passes through (no over-block)" \
  || fail "a plain URL merge was blocked"
grep -q "^pr merge $URL --squash$" "$SCEN/calls" && pass "  …with argv untouched" \
  || fail "  …but argv changed: $(cat "$SCEN/calls")"

# (f) A URL inside a flag VALUE is not the selector — and the VULNERABLE ordering is the
# value BEFORE the positional. gh accepts interspersed flags, so
# `gh pr merge --body "see <url>" 123 --admin` really merges 123; the gate must verify
# 123, not the URL's PR in the URL's repo. (The shim was never exposed here — argv is
# already dequoted, so the whole quoted body is ONE value — but the scanner IS a string
# layer, and a whitespace split there made this a fail-open. Pinned on both sides: this
# suite drives the argv layer, `index.test.ts` drives the scanner.)
#
# The fixture serves the SAME head and comments whatever number is asked for, so the
# `pr view` ARGV is the discriminator — an exit code alone would pass either way.
new_scen urlbodyvalue
jq -n --rawfile b "$TMP/body-url" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
bash "$SHIM" pr merge --body "see $URL here" 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && pass "a value-hosted URL before the positional → resolved, not confused (exit 0)" \
  || { fail "the value-before-positional form was refused"; sed 's/^/      /' "$TMP/err"; }
grep -q "pr view 123 " "$SCEN/calls" && pass "  …the verifier resolved the POSITIONAL (123)" \
  || fail "  …the verifier did not resolve 123: $(head -1 "$SCEN/calls")"
grep -q "pr view 1006 " "$SCEN/calls" && fail "  …the body URL was read as the PR (fail-open)" \
  || pass "  …the body URL was NOT read as the PR"

# The same ordering with an ESCAPED quote inside the value: bash keeps the value open
# (the `\"` does not close it) and the whole thing is ONE argv value, so the positional
# still wins. The scanner needed a fix for this shape; the argv layer never did.
new_scen urlbodyescaped
jq -n --rawfile b "$TMP/body-url" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
SCEN="$SCEN" bash "$SHIM" pr merge --body "a\" $URL b" 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
grep -q "pr view 123 " "$SCEN/calls" && pass "  …an escaped quote inside the value still resolves 123" \
  || fail "  …an escaped quote broke the value: $(head -1 "$SCEN/calls")"
grep -q "pr view 1006 " "$SCEN/calls" && fail "  …the escaped-quote body URL became the PR (fail-open)" \
  || pass "  …the escaped-quote body URL was NOT read as the PR"

# NOTE: an ATTACHED `--hostname=` (`gh pr merge 123 --admin --hostname=github.com`) is
# covered by §10(d) above — the over-block that motivated adding it to the shared
# attached-value case (#1007 VGATE cycle 2) is pinned there with a full evidence fixture.

# (g) PARITY TRIPWIRE with the outer scanner. This is not a proof of equivalence — it
# fails when the TS shape is edited without the bash one being revisited, which is the
# drift that produces an over-block in one layer and an accept in the other.
grep -Fq 'PR_URL_RE = /^https:\/\/github\.com\/([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+)\/pull\/([0-9]+)$/' \
  "$ROOT/extensions/review-enforcer/index.ts" \
  && pass "the scanner carries the same URL shape (parity tripwire)" \
  || fail "the scanner's PR_URL_RE changed shape — revisit the shim's parse_pr_url"

# …and the SAME tripwire in the other direction (VGATE #1007 cycle 4): the loop in (d)
# pins 21 refusals BEHAVIOURALLY, but a NEW permissive shape added here while the scanner
# is edited to match would otherwise drift unpinned. These two literals are what "the same
# shape" means — the host and the allowed owner/repo charset.
grep -Fq 'https://github.com/' "$ROOT/scripts/gh-shim/gh" \
  && grep -Fq '*[!A-Za-z0-9_.-]*' "$ROOT/scripts/gh-shim/gh" \
  && pass "the shim carries the same host + charset (parity tripwire, other direction)" \
  || fail "the shim's parse_pr_url changed shape — revisit the scanner's PR_URL_RE"

# (h) A BARE number obeys the SAME rule as the URL form — no leading zero, at most 15
# digits. The scanner holds a JS `Number` (which normalises `01006` and ROUNDS above
# 2^53) while this argv layer passes the literal digits to gh, so without this rule the
# two layers can name different PRs and the gate reads the wrong PR's evidence (fresh
# review, P2). The scanner refuses the same set — see index.test.ts.
#
# The fixture must be CERTIFYING: the number guard exits before the verifier, so without
# evidence the verifier would refuse anyway and this case passed even with the guard
# removed (round-4 review P3 — a test that cannot tell). With evidence served for whatever
# number is asked, the ONLY thing that can refuse is the number rule, and removing it lets
# `pr merge` reach the fake gh (rc=0) — the mutation the assertion exists to catch.
for badnum in 0 01006 0001 9007199254740993 9999999999999999; do
  new_scen "badnum$badnum"
  jq -n --rawfile b "$TMP/body-url" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
  bash "$SHIM" pr merge "$badnum" --admin >/dev/null 2>"$TMP/err"; rc=$?
  if [ "$rc" -ne 0 ] && ! grep -q "pr merge" "$SCEN/calls" \
     && grep -qE "both this shim and the scanner|cannot be held exactly by the scanner" "$TMP/err"; then
    pass "a bare \`$badnum\` → REFUSED by the number rule (exit $rc)"
  else
    fail "a bare \`$badnum\` was not refused by the number rule (rc=$rc): $(head -1 "$TMP/err")"
  fi
done

# ── 12. the shapes around the deferral: what the TEXT layer hands over, and what it
#        keeps for itself (#1776). The extension declines its GUESS on the admin-merge
#        question whenever this shim is installed and executable (`ghShimWillEnforce`) —
#        but only for a command it does not READ as a merge (`mergeVerbInText`), and a
#        shape whose merge verb it reads keeps the fail-closed text-layer decision
#        (pinned end-to-end in the extension suite). So the arms below pin THIS layer's
#        refusals for the whole family, and the one shape the extension does hand over is
#        the #1775 over-read: a construct plus the word `admin` with NO merge in the text
#        (a PR title supplying the word). Pinned in BOTH polarities — refused with no
#        evidence, and ALLOWED with evidence — because a mis-parse can refuse for the
#        wrong reason, but it cannot let the merge through with the caller's argv intact.
#        (a)-(d) are SHIM-ONLY arms: each ends in a LITERAL `--admin`, which keeps the
#        text-layer decision, so they are here to prove this layer refuses them too, not
#        because they are deferred.
#        (e) is NOT deferred either: the flag comes from a VARIABLE, but the verb is read
#        (the stripper leaves `$M` in the verb position), so the extension decides it and
#        this arm pins the argv layer's refusal of the same command.
echo "== 12. the shapes around the deferral (#1776) =="
for shape in 'pr --repo owner/other merge 123' 'pr -Rowner/other merge 123' \
             '--repo owner/other pr merge 123' '--repo=owner/other pr merge 123'; do
  tag="defer$(echo "$shape" | tr -dc 'a-z0-9')"
  # (a) no evidence at all in the fixture → this layer must refuse.
  new_scen "$tag-no"
  bash "$SHIM" $shape --admin >/dev/null 2>"$TMP/err"; rc=$?
  if [ "$rc" -ne 0 ] && ! grep -q "pr merge" "$SCEN/calls"; then
    pass "\`gh $shape --admin\` with no evidence → REFUSED (exit $rc)"
  else
    fail "\`gh $shape --admin\` was ALLOWED with no evidence (rc=$rc)"
  fi
  # (b) certifying evidence for the current head → allowed, and the forwarded argv must
  # be the ORIGINAL spelling, ANCHORED. An unanchored `--repo owner/other` also matches
  # the VERIFIER's own normalised call — a different line in the same file — so it would
  # pass even if the forwarded spelling had been mangled.
  new_scen "$tag-yes"
  jq -n --rawfile b "$TMP/body-good" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
  bash "$SHIM" $shape --admin >/dev/null 2>"$TMP/err"; rc=$?
  if [ "$rc" -eq 0 ] && grep -q -- "^$shape --admin$" "$SCEN/calls"; then
    pass "  …with head-bound evidence → allowed, and the ORIGINAL argv was forwarded intact"
  else
    fail "  …evidence did not open \`gh $shape --admin\` intact (rc=$rc): $(head -1 "$TMP/err")"
  fi
done
# The verb SPLICED, so the resolved argv is the only place the word `merge` exists.
# (The text layer reads this one too — `$M` lands in the verb position after the repo flag
# is stripped — so the arm pins THIS layer's refusal, not a text-side defeat.)
new_scen defer-spliced
M=merge
bash "$SHIM" pr --repo owner/other "$M" 123 --admin >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q "pr merge" "$SCEN/calls" \
  && pass "a \$VAR-supplied verb BEHIND a repo flag → REFUSED (exit $rc)" \
  || fail "a spliced verb behind a repo flag slipped past"

# The verb SPLICED and the FLAG supplied by a variable — neither is a literal token, but
# this is NOT a deferred shape at the extension layer: the repo-flag stripper leaves `$M`
# in the verb position, so the extension reads the text as a merge (`mergeVerbInText`) and
# keeps its own fail-closed decision. This arm pins that the SHIM refuses it too, which is
# what a command of this family faces if the extension's decision is ever overridden.
new_scen defer-spliced-noflag
M=merge
V=--admin
bash "$SHIM" pr --repo owner/other "$M" 123 "$V" >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -ne 0 ] && ! grep -q "pr merge" "$SCEN/calls" \
  && pass "a \$VAR verb AND a \$VAR flag behind a repo flag → REFUSED (exit $rc)" \
  || fail "a spliced verb + variable flag slipped past"
new_scen defer-spliced-noflag-yes
jq -n --rawfile b "$TMP/body-good" '{headRefOid:"'"$HEAD_A"'",comments:[{body:$b}]}' > "$SCEN/pr.json"
bash "$SHIM" pr --repo owner/other "$M" 123 "$V" >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && grep -q -- "--repo owner/other" "$SCEN/calls" \
  && pass "  …with head-bound evidence → allowed (the decisive half of the pair)" \
  || fail "  …valid evidence did not open the variable-flag shape (rc=$rc)"

# STATED LIMIT, pinned so it cannot be mistaken for coverage: `gh alias`. gh expands an
# alias AFTER this process has run, so an alias whose body is `pr merge --admin` is
# invisible to BOTH layers (the shim's own header declares it). This asserts the
# pass-through, which is the honest statement of the hole — NOT a claim that it is closed.
new_scen alias-limit
bash "$SHIM" ship-it 123 >/dev/null 2>"$TMP/err"; rc=$?
[ "$rc" -eq 0 ] && grep -q "^ship-it 123$" "$SCEN/calls" \
  && pass "STATED LIMIT (declared, not closed): an alias-shaped argv passes through to gh" \
  || fail "the alias pass-through changed shape — revisit the declared limit"

# ── 13. THE FLEET COURTESY GATE (#1910) ─────────────────────────────────────
# The account's SECONDARY limit is a CONCURRENCY limit shared across every machine, and
# `GET /rate_limit` reports only the primary budget — so a healthy `graphql.remaining`
# beside a refused call is the documented blind spot, not a contradiction. These arms
# pin the four mechanisms by their observable behaviour, with real timings:
#   13(a) at most MAX_INFLIGHT gh processes per machine,
#   13(b) a minimum interval between call STARTS,
#   13(c) `retry-after` is honoured (and the retry is never immediate),
#   13(d) with no `retry-after`, the wait is the documented >=60 s,
#   13(e) a burst of N lanes produces ONE refusal-and-wait, not N failures (the AC),
#   13(f) the exempt `rate_limit` read can only LIFT a shared window, never admit under one,
#   13(g) a non-rate-limit 403 is NOT retried (a mutating command must not run twice).
echo "== 13. the fleet courtesy gate: bounded concurrency, spacing, 403/429 handling (#1910) =="

# A hermetic gate state per arm: never the operator's ~/.pi/agent/gh-gate.
gate_dir() { local d="$TMP/gate-$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }

# (a) BOUNDED CONCURRENCY. The fake gh holds a marker file for 0.4 s so overlap is
#     measurable. 4 lanes, cap 2 → 2, never 4.
#     ⛔ EACH CHILD RECORDS THE COUNT IT SAW AT ITS OWN START — DETERMINISTICALLY (#1910 run).
#     The wall-clock sampler this replaced read the marker dir on a 50 ms timer and published its
#     running max into a file; on a loaded runner the arm failed with `saw  in flight` — an EMPTY
#     sample, not a violation — i.e. the SURFACE for the assertion had vanished and the arm reported
#     it as a broken cap. A measurement artifact was printed as a finding. Admission is what this arm
#     is about: an over-admitted child is the one that SEES the extra sibling, so asking every child
#     "how many were active when you started?" observes every admission with no timer to miss it.
#     (Same shape as 16's NO_WAIT slot arm: "a sampler that runs after `wait` reads 0 and would pass
#     with the cap wide open (it did)".)
GDIR="$(gate_dir conc)"; GACTIVE="$TMP/gate-conc-active"; rm -rf "$GACTIVE"; mkdir -p "$GACTIVE"
GREAL="$TMP/gate-real-conc"; GSEEN="$TMP/gate-conc-seen"; : > "$GSEEN"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
: > "$GACTIVE/$$"
echo "$(ls "$GACTIVE" | wc -l | tr -d ' ')" >> "$GSEEN"
sleep 0.4
rm -f "$GACTIVE/$$"
exit 0
GHEOF
chmod +x "$GREAL"
gpids=""
for _lane in 1 2 3 4; do
  GACTIVE="$GACTIVE" GSEEN="$GSEEN" AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" \
    AGENT_GH_GATE_MAX_INFLIGHT=2 AGENT_GH_GATE_INTERVAL_MS=0 \
    bash "$SHIM" api user >/dev/null 2>&1 &
  gpids="$gpids $!"
done
for p in $gpids; do wait "$p"; done
maxc=0; seen=0
while read -r _n; do
  case "$_n" in ''|*[!0-9]*) continue ;; esac
  seen=$(( seen + 1 ))
  [ "$_n" -gt "$maxc" ] && maxc="$_n"
done < "$GSEEN"
# An EMPTY observation set proves nothing and must not be graded as a violation of the cap: it is a
# different fault (nothing ran, or nothing recorded) and it says so in its own words.
# ⛔ AND A PARTIAL SET IS NOT AN OBSERVATION OF THIS ARM'S PREMISE EITHER (#1881 review P2). Each of
# the four children writes exactly one line at its own admission, so `seen` is the number that
# REACHED the gate. Grading `seen == 1` as a pass let three lanes be refused — or silently never
# start — and still report "4 parallel lanes … at most 2 in flight": the arm would be green over a
# population one quarter the size of the one it names. `seen` must therefore be all four; a smaller
# count is its own fault, named as such, not a cap verdict.
if [ "$seen" -lt 4 ]; then
  fail "only $seen of 4 gh children reached the gate, so this sample does not contain the four admissions the arm claims to observe"
elif [ "$maxc" -le 2 ] && [ "$maxc" -ge 1 ]; then
  pass "4 parallel lanes with MAX_INFLIGHT=2 → at most 2 gh processes in flight (saw $maxc, $seen child observation(s))"
else
  fail "the concurrency bound did not hold: saw $maxc in flight with a cap of 2"
fi
[ -z "$(ls "$GDIR/slots" 2>/dev/null | head -1)" ] \
  && pass "  …and every slot was released (no leak to wedge the next lane)" \
  || fail "  …but slots were left behind: $(ls "$GDIR/slots")"

# (b) SPACING. Three calls, interval 1 s (a whole second on purpose: the assertion then
#     holds whatever the clock's granularity, and `date +%s` is portable to macOS).
#     ⛔ ASSERT THE TOTAL, NOT EACH GAP. Three calls at interval I guarantee start3 - start1 >= 2I
#     whatever each child costs; asserting every PAIR is margin-dependent — one child's startup
#     jitter moves a single gap and the arm fails while the spacing actually held (observed:
#     083, 083, 085 — a zero gap plus a double gap, total still 2 s). The total is discriminating:
#     with no spacing it collapses to 0-1 s.
GDIR="$(gate_dir spacing)"; GTIMES="$TMP/gate-times"; : > "$GTIMES"
GREAL="$TMP/gate-real-time"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
date +%s >> "$GTIMES"
exit 0
GHEOF
chmod +x "$GREAL"
for _lane in 1 2 3; do
  GTIMES="$GTIMES" AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=1000 \
    bash "$SHIM" api user >/dev/null 2>&1
done
spacing_ok=1
first=""; last=""
while read -r t; do
  [ -z "$first" ] && first="$t"
  last="$t"
done < "$GTIMES"
[ -n "$first" ] && [ -n "$last" ] && [ $(( last - first )) -ge 2 ] && spacing_ok=1 || spacing_ok=0
[ "$spacing_ok" -eq 1 ] && [ "$(wc -l < "$GTIMES")" -ge 3 ] \
  && pass "3 sequential calls at INTERVAL_MS=1000 → total span >= 2 s (serialised)" \
  || fail "the minimum interval was not enforced: starts were $(tr '\n' ' ' < "$GTIMES")"

# (c) `retry-after` IS HONOURED, and the retry is NEVER immediate. The fake refuses once,
#     asks for 1 s, then succeeds. The gap between the two attempts must be ~1 s — an
#     immediate identical retry is the `3/3 attempts, identical` loop #1762 recorded.
GDIR="$(gate_dir retryafter)"; GTIMES="$TMP/gate-429-times"; GCOUNT="$TMP/gate-429-count"
: > "$GTIMES"; rm -f "$GCOUNT"
GREAL="$TMP/gate-real-429"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
n=$(cat "$GCOUNT" 2>/dev/null || echo 0); n=$(( n + 1 )); printf '%s' "$n" > "$GCOUNT"
date +%s >> "$GTIMES"
if [ "$n" -eq 1 ]; then
  echo "HTTP 403: API rate limit already exceeded for user ID 12345. (retry-after: 1) (https://api.github.com/graphql)" >&2
  exit 1
fi
echo "attempt $n"
exit 0
GHEOF
chmod +x "$GREAL"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  GCOUNT="$GCOUNT" GTIMES="$GTIMES" \
  bash "$SHIM" api graphql -f query=x >"$TMP/gate-429-out" 2>"$TMP/gate-429-err"; rc=$?
att1=$(sed -n '1p' "$GTIMES"); att2=$(sed -n '2p' "$GTIMES")
if [ "$rc" -eq 0 ] && [ "$(cat "$GCOUNT")" -eq 2 ] && [ -n "$att2" ] \
   && [ $(( att2 - att1 )) -ge 1 ]; then
  pass "403 + \`retry-after: 1\` → retried once after the required wait (${att1}→${att2}), then succeeded"
else
  fail "the 403 retry did not honour \`retry-after\` (rc=$rc attempts=$(cat "$GCOUNT" 2>/dev/null) starts='$(tr '\n' ' ' < "$GTIMES")')"
fi
grep -q 'waiting 1s' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and the wait was recorded in events.log (a silent 60 s sleep is indistinguishable from a hang)" \
  || fail "  …but the wait was never announced: $(head -2 "$GDIR/events.log" 2>/dev/null | tr '\n' ' ')"
# ⛔ …AND IT MUST NOT HAVE BEEN ANNOUNCED ON STDERR: this call SUCCEEDED, and `gh-rest/gh`
# parses `2>&1`, so a note here is a JSONDecodeError on the caller's good answer.
if grep -q 'gh-gate:' "$TMP/gate-429-err" 2>/dev/null; then
  fail "  …BUT it put a pacing note on a SUCCESSFUL call's stderr: $(head -2 "$TMP/gate-429-err" | tr '\n' ' ')"
else
  pass "  …and a successful call's stderr stayed byte-clean (the gh-rest 2>&1 parse is safe)"
fi
grep -q 'attempt 2' "$TMP/gate-429-out" \
  && pass "  …and stdout of the retried attempt is what the caller sees" \
  || fail "  …but the retried attempt's stdout was lost: $(cat "$TMP/gate-429-out")"

# (c2) THE BUDGET LINE (#gh-quota). A refusal is the ONE moment the gate KNOWS the account
#      is at zero, and that knowledge used to die with the process: the next beat saw a rail
#      exit 1 and read it as a PRODUCT fault (2026-11-03 — `gh run list` 403 for user id
#      81560491 while ~20 lanes each suspected their own PR). The window the gate already
#      writes to `cooldown.*` IS the budget, so it is published in ONE cheap read: no API
#      call, and no second predicate — `remaining=0` means exactly "this gate is holding the
#      box out of calls until resets_at".
GDIR="$(gate_dir budgetline)"; rm -f "$TMP/gate-budget-count"
GREAL="$TMP/gate-real-budget"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
echo "API rate limit exceeded for user ID 12345." >&2
exit 1
GHEOF
chmod +x "$GREAL"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  AGENT_GH_GATE_NO_WAIT=1 GCOUNT="$GCOUNT" \
  bash "$SHIM" api graphql -f query=x >/dev/null 2>&1
if [ -f "$GDIR/budget" ] && grep -qE '^GH-BUDGET\(remaining=0, resets_at=[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\)$' "$GDIR/budget"; then
  pass "a refusal publishes the budget in one cheap read: $(cat "$GDIR/budget")"
else
  fail "no readable budget line after a refusal: $(cat "$GDIR/budget" 2>/dev/null || echo '<absent>')"
fi
# ⛔ AND IT MUST NOT OUTLIVE ITS WINDOW. A stale `remaining=0` is a lie the next beat acts on,
# so the reader that prunes expired windows prunes this too.
_until=$(( $(date +%s) * 1000 - 5000 ))
# The FIRST call's refusal left a LIVE 60 s window; clear it, so this arm tests the
# expired-window path rather than "some other window is still running".
rm -f "$GDIR"/cooldown.*
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
printf '%s\n' 'GH-BUDGET(remaining=0, resets_at=2026-01-01T00:00:00Z)' > "$GDIR/budget"
# The two files travel together: `budget.until` is the deadline the line was written
# for, and it is what decides removal (a glob snapshot of `cooldown.*` cannot).
printf '%s\n' "$_until" > "$GDIR/budget.until"
# A call that SUCCEEDS: a refusal here would legitimately write a NEW window (and its
# budget line), which would make the assertion below vacuous.
GOK="$TMP/gate-real-ok"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GOK"; chmod +x "$GOK"
AGENT_GH_REAL="$GOK" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  AGENT_GH_GATE_NO_WAIT=1 AGENT_GH_GATE_RETRY_MAX=1 \
  bash "$SHIM" api user >/dev/null 2>&1
[ -f "$GDIR/budget" ] \
  && fail "a budget line outlived its window — the next beat would read remaining=0 as current" \
  || pass "  …and it is removed once no window is live (a stale remaining=0 cannot be read as current)"

# ⛔ AND THE PROTECTIVE HALF: a budget line whose OWN deadline is still in the future
# must SURVIVE a read that sees no live `cooldown.*` file. That is the stale-glob case
# the prune's `budget.until` check exists for; without this arm, reverting to "delete
# whenever the glob shows nothing" would keep the suite green.
GDIR="$(gate_dir budgetkeep)"
rm -f "$GDIR"/cooldown.* "$GDIR/budget" "$GDIR/budget.until"
_future=$(( $(date +%s) * 1000 + 600000 ))
printf '%s\n' "$_future" > "$GDIR/budget.until"
printf '%s\n' "GH-BUDGET(remaining=0, resets_at=2030-01-01T00:00:00Z)" > "$GDIR/budget"
GOK2="$TMP/gate-real-ok2"
printf '#!/usr/bin/env bash\nexit 0\n' > "$GOK2"; chmod +x "$GOK2"
AGENT_GH_REAL="$GOK2" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  AGENT_GH_GATE_NO_WAIT=1 bash "$SHIM" api user >/dev/null 2>&1
[ -f "$GDIR/budget" ] \
  && pass "  …and a line whose OWN deadline is still ahead SURVIVES a read with no live cooldown.* (the prune reads budget.until, not a glob snapshot)" \
  || fail "a live budget line was deleted because no cooldown.* file was visible — the prune is reading a stale glob"

# ⛔ AND THE PRIMARY/SECONDARY DISTINCTION MUST BE PINNED, not merely implemented: the
# positive arm above passes whether or not `budget_signature` exists, so without this
# arm the whole "only the BUDGET publishes remaining=0" claim could be deleted and the
# suite would stay green (measured: a secondary refusal at `used: 541` of 5000 would
# then publish remaining=0).
GDIR="$(gate_dir budgetsecondary)"; rm -f "$TMP/gate-secondary-count"
GREAL="$TMP/gate-real-secondary"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
echo "You have exceeded a secondary rate limit. Please wait a few minutes before you try again." >&2
exit 1
GHEOF
chmod +x "$GREAL"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  AGENT_GH_GATE_NO_WAIT=1 \
  bash "$SHIM" api graphql -f query=x >/dev/null 2>&1
ls "$GDIR"/cooldown.* >/dev/null 2>&1 \
  && pass "  …a SECONDARY/concurrency refusal still parks the box (the shared window is written)" \
  || fail "  …a secondary refusal wrote no shared window — the gate stopped pacing"
[ -f "$GDIR/budget" ] \
  && fail "a SECONDARY-limit refusal published GH-BUDGET(remaining=0) — the account's budget was not measured" \
  || pass "  …but it does NOT publish remaining=0: a concurrency limit is not budget exhaustion"

# ⛔ THE MEASURED SECONDARY SPELLING, which no arm pinned: GitHub's concurrency refusal is
# "API rate limit ALREADY exceeded for user ID …" — the phrase this fleet has recorded as
# SECONDARY (`gh-limit.py` SECONDARY_PHRASES, `pr-doctor.py`, `docs/ops/gh-rate-limits.md`:
# "while the primary counter reads healthy", measured at 4999/5000). A `budget_signature`
# that treats `already` as an optional part of the PRIMARY phrase publishes exhaustion on
# it — the exact misdiagnosis the line exists to prevent.
GDIR="$(gate_dir budgetsecondary2)"; rm -f "$TMP/gate-secondary2-count"
GREAL="$TMP/gate-real-secondary2"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
echo "GraphQL: API rate limit already exceeded for user ID 81560491." >&2
exit 1
GHEOF
chmod +x "$GREAL"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  AGENT_GH_GATE_NO_WAIT=1 \
  bash "$SHIM" api graphql -f query=x >/dev/null 2>&1
# The POSITIVE half: it must still be recognised as a rate limit (a shared window, i.e.
# pacing preserved). Without this, an implementation that stopped matching the spelling
# AT ALL would pass the absence assertion below while pacing nothing.
ls "$GDIR"/cooldown.* >/dev/null 2>&1 \
  && pass "  …and it is still PACED (the shared window is written): classified secondary, not unclassified" \
  || fail "  …not recognised as a rate limit at all — the absence assertion below proves nothing"
[ -f "$GDIR/budget" ] \
  && fail "the MEASURED secondary spelling ('already exceeded for user ID') published remaining=0 — a healthy primary budget was reported as exhausted" \
  || pass "  …and the MEASURED secondary spelling ('already exceeded for user ID') does not publish it either"

# (d) NO `retry-after` → the documented >=60 s, not an immediate retry. A 60 s sleep cannot
#     be waited out in a suite, so this pins the ANNOUNCED wait (the number the gate would
#     sleep) by intercepting the call after the announcement: the shim is stopped while it
#     sleeps, and the announcement is what is asserted.
GDIR="$(gate_dir noretryafter)"; GCOUNT="$TMP/gate-60-count"; rm -f "$GCOUNT"
GREAL="$TMP/gate-real-60"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
n=$(cat "$GCOUNT" 2>/dev/null || echo 0); n=$(( n + 1 )); printf '%s' "$n" > "$GCOUNT"
echo "API rate limit exceeded for user ID 12345." >&2
exit 1
GHEOF
chmod +x "$GREAL"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  GCOUNT="$GCOUNT" \
  bash "$SHIM" api graphql -f query=x >/dev/null 2>"$TMP/gate-60-err" &
slow=$!
sleep 3
kill "$slow" 2>/dev/null
for _child in $(pgrep -P "$slow" 2>/dev/null); do kill "$_child" 2>/dev/null; done
wait "$slow" 2>/dev/null
grep -q 'waiting 60s' "$TMP/gate-60-err" \
  && pass "no \`retry-after\` → waits 60 s (GitHub's own guidance), never an immediate retry" \
  || fail "the no-header wait is not the documented 60 s: $(head -2 "$TMP/gate-60-err" | tr '\n' ' ')"
[ "$(cat "$GCOUNT" 2>/dev/null || echo 0)" -eq 1 ] \
  && pass "  …and no second attempt was issued inside the first 3 s (it was waiting, not retrying)" \
  || fail "  …but a second attempt was issued before the wait elapsed"

# (e) THE ACCEPTANCE: a burst of N lanes produces ONE refusal-and-wait, not N failures.
#     ⛔ THE WINDOW IS ARMED BY THE FIRST REFUSAL, NOT BY THE TEST'S OWN START TIME. A fixed
#     wall-clock window ("refuse for the first 1.2 s") made this arm FLAKY: on a loaded box no lane
#     had even started inside 1.2 s, so nothing was refused and the arm failed with "0 refusal(s)"
#     while the cooldown was working perfectly (measured 2 of 3 runs on a busy box). Here the fake
#     keeps refusing until a refusal has been RECORDED, then for 1.2 s more — so the first lane is
#     always refused, and any lane that does NOT wait out the cooldown refuses again and is counted.
GDIR="$(gate_dir burst)"; GLIMIT="$TMP/gate-limit"; GREF="$TMP/gate-refusals"
: > "$GLIMIT"; : > "$GREF"
GREAL="$TMP/gate-real-burst"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
if [ -e "$GLIMIT" ]; then
  echo R >> "$GREF"
  echo "API rate limit already exceeded for user ID 12345. (retry-after: 2)" >&2
  exit 1
fi
sleep 0.05
exit 0
GHEOF
chmod +x "$GREAL"
( _guard=0; while [ ! -s "$GREF" ] && [ "$_guard" -lt 600 ]; do sleep 0.05; _guard=$(( _guard + 1 )); done
  sleep 1.2; rm -f "$GLIMIT" ) &
window=$!
gpids=""
for _lane in 1 2 3 4 5; do
  GLIMIT="$GLIMIT" GREF="$GREF" AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" \
    AGENT_GH_GATE_MAX_INFLIGHT=1 AGENT_GH_GATE_INTERVAL_MS=0 \
    bash "$SHIM" api user >/dev/null 2>>"$TMP/gate-burst-err" &
  gpids="$gpids $!"
done
burst_rcs=""
for p in $gpids; do wait "$p"; burst_rcs="$burst_rcs $?"; done
wait "$window" 2>/dev/null
refusals=$(grep -c . "$GREF" 2>/dev/null || true)
case "$burst_rcs" in
  *[!0\ ]*) all_ok=0 ;;
  *) all_ok=1 ;;
esac
[ "${refusals:-0}" -eq 1 ] \
  && pass "5 parallel lanes hitting ONE refusal window → exactly 1 refusal (not 5)" \
  || fail "the burst was not absorbed by the shared cooldown: $refusals refusal(s), expected 1"
[ "$all_ok" -eq 1 ] \
  && pass "  …and all 5 lanes finished rc=0 (one refusal-and-wait, no lane failed)" \
  || fail "  …but some lanes failed: rc list '$burst_rcs'"

# (f) THE GATE's HEALTH SIGNAL IS ITS OWN IN-FLIGHT COUNT — AND THE EXEMPT `/rate_limit` READ MAY
#     ONLY EVER *LIFT* A WINDOW, NEVER ADMIT UNDER ONE. `GET /rate_limit` reports only the primary
#     budget, so a refusal it cannot see (secondary/abuse) must never be discharged by it (#1762).
#
#     ⛔ THIS ARM USED TO BE A STATIC GREP — "no executed line references the endpoint" — AND THAT
#     PIN WAS SATISFIED BY A FIX THAT DISCHARGED NOTHING AT ALL. A three-line `python3 -c` body with
#     a leading space on line 2 raises IndentationError, the parser reported "unreadable body", the
#     window was honoured, and the grep was green over a revalidation that could never fire
#     (measured: a 110 s window slept out in full, 112.9 s, while the account had core 3,502/5,000).
#     The invariant is BEHAVIOURAL, so it is pinned behaviourally: the read lifts a window when the
#     account is healthy, and it CANNOT lift one a secondary refusal wrote or one it cannot verify.
#     `AGENT_GH_GATE_WAIT_BUDGET=1` keeps a non-discharge at ~1 s (rc=75) instead of a 60 s sleep.
GDIR="$(gate_dir revalidate)"
GREAL="$TMP/gate-real-revalidate"
# A fake gh that answers the exempt read with a HEALTHY body and everything else with silence.
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*)
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684},"graphql":{"limit":5000,"remaining":4976},"search":{"limit":30,"remaining":30}}}'
    exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$GREAL"
# A fake gh whose exempt read FAILS — absence of evidence must never discharge a window.
GREAL_BAD="$TMP/gate-real-revalidate-bad"
cat > "$GREAL_BAD" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*) echo 'HTTP 403: API rate limit exceeded for user ID 81560491' >&2; exit 1 ;;
esac
exit 0
GHEOF
chmod +x "$GREAL_BAD"

# (f)(i) a HEALTHY account LIFTS a far-future window: the call proceeds now, not in 60 s.
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
: > "$GDIR/events.log"
_ns=$(date +%s)
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
_ne=$(date +%s)
[ "$_rc" -eq 0 ] && [ $(( _ne - _ns )) -le 5 ] \
  && pass "a healthy exempt read lifts a 60 s window (rc=0 in $(( _ne - _ns ))s, not 60s)" \
  || fail "the window was NOT re-derived: rc=$_rc after $(( _ne - _ns ))s — the revalidation is a no-op"
grep -q 'DISCHARGED' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and it is recorded as DISCHARGED, with the core number it read" \
  || fail "  …and nothing said DISCHARGED — the window vanished silently or not at all"
ls "$GDIR"/cooldown.* >/dev/null 2>&1 \
  && fail "  …but the cooldown files are still there, so the next lane still sleeps" \
  || pass "  …and the stale cooldown files are gone (the whole box is released, not just this call)"

# (f)(ii) A SECONDARY/abuse window is INVISIBLE to `/rate_limit`, so a healthy primary read must
#         NOT discharge it. This is the #1762 mistake, pinned: same healthy body, honoured anyway.
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
: > "$GDIR/secondary.window"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "a SECONDARY window is honoured even when core reads healthy (rc=75 contended)" \
  || fail "a secondary window was discharged by a primary read (rc=$_rc) — this is the #1762 mistake"
grep -q 'DISCHARGED' "$GDIR/events.log" 2>/dev/null \
  && fail "  …and it was recorded as DISCHARGED — the secondary flag did not gate the read" \
  || pass "  …and nothing was discharged"

# (f)(iii) A revalidation that CANNOT COMPLETE leaves the window exactly as it was — absence of
#          evidence is never a discharge (a transient 502 must not delete a real window).
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
rm -f "$GDIR/secondary.window"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_BAD" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "a FAILED exempt read honours the window (rc=75) — no evidence, no discharge" \
  || fail "a failed exempt read discharged the window (rc=$_rc) — absence was read as health"
grep -q 'could not re-derive' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and says so, rather than passing silently" \
  || fail "  …and the failure was silent"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# (f)(iv)–(f)(viii) — THE ARMS #3228's FIRST REVIEW FOUND MISSING. Each is tied to a measured
# fail-open, and each is written so it CANNOT pass for the wrong reason: (f)(v) is the anti-inert
# control for (f)(iv)/(f)(vi) — without it, a gate that never discharges anything would look green.
# ══════════════════════════════════════════════════════════════════════════════════════════════
# A fake gh whose exempt read reports a HEALTHY core and an EXHAUSTED graphql bucket — the shape a
# `pr view` refusal produces, and the one the core-only reader discharged (finding 3).
GREAL_GQL="$TMP/gate-real-revalidate-graphql"
cat > "$GREAL_GQL" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*)
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684},"graphql":{"limit":5000,"remaining":0},"search":{"limit":30,"remaining":30}}}'
    exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$GREAL_GQL"

# (f)(iv) EVERY BUCKET, not just core: an exhausted graphql keeps its window.
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
rm -f "$GDIR/secondary.window"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_GQL" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" pr view 1 >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "(f)(iv) an EXHAUSTED graphql bucket keeps its window even though core reads healthy (rc=75)" \
  || fail "(f)(iv) a graphql refusal was DISCHARGED on a healthy core (rc=$_rc) — the corroboration only read core"
grep -q 'CORROBORATED' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and it is recorded as CORROBORATED, naming the low bucket" \
  || fail "  …and the refusal reason was not recorded"

# (f)(v) ⛔ THE ANTI-INERT CONTROL. The stricter read must STILL discharge a healthy account —
# including `search`, whose whole limit (30) is far below the absolute floor (100). A naive
# "every bucket above the floor" test calls this healthy account exhausted and turns the entire fix
# into a no-op that reports itself green — the failure mode #3228's review warned about.
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" pr view 1 >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] \
  && pass "(f)(v) a healthy account is STILL discharged — the small search bucket does not make the gate inert (rc=0)" \
  || fail "(f)(v) the gate is INERT: a healthy account (search 30/30) was treated as exhausted (rc=$_rc)"

# (f)(vi) THE CORROBORATED DIRECTION IS PINNED TOO (finding 9). A floor at or above the remaining
# count of a bucket that is genuinely MORE THAN HALF SPENT must HONOUR the window. This is the branch
# that fails toward "always discharge" if it inverts, and the PR body claimed it was proven while
# nothing referenced the floor at all.
# ⛔ THE FIXTURE MOVED WITH THE PREDICATE, AND THE MOVE IS THE POINT. This arm used to read
# `core 4684/5000` at floor 4999 — i.e. it demanded that a 93%-HEALTHY bucket be called exhausted
# purely because the operator set a high floor. That is the same defect as P1-a one layer up: the
# floor overriding the bucket's own headroom. The floor now corroborates only a bucket at or below
# half its limit, so the arm drives `core 1500/5000` (30% left — over the 10% rule's line, so ONLY
# the floor branch can fire) at floor 2000. The pass message names the bucket it acted on, so the arm
# cannot go green because some other body made it low.
GREAL_FLOOR="$TMP/gate-real-revalidate-floor"
cat > "$GREAL_FLOOR" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*)
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":1500},"graphql":{"limit":5000,"remaining":4976},"search":{"limit":30,"remaining":30}}}'
    exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$GREAL_FLOOR"
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_GATE_REVALIDATE_FLOOR=2000 AGENT_GH_REAL="$GREAL_FLOOR" \
  AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "(f)(vi) a floor ABOVE a half-spent bucket's remaining HONOURS the window (core 1500/5000, floor 2000 → rc=75)" \
  || fail "(f)(vi) REVALIDATE_FLOOR did not corroborate: rc=$_rc — the floor branch is dead"
grep -q 'core 1500/5000' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and the corroborating bucket is the one the FLOOR caught (core 1500/5000)" \
  || fail "  …but the note names a different bucket: '$(grep 'bucket is low' "$GDIR/events.log" 2>/dev/null | head -1)'"

# (f)(vii) ⛔ A SECONDARY WINDOW SURVIVES A PEER'S ORDINARY REFUSAL (finding 2). The flag records
# the deadline it protects; the old code rm'd it on every non-secondary refusal, un-protecting a
# LONGER secondary window that still governed the box (deadlines are monotonic maxima).
GDIR2="$(gate_dir revalidate-secondary)"
GDIR="$GDIR2"
GREAL_SEC="$TMP/gate-real-secondary"
cat > "$GREAL_SEC" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*) printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684}}}'; exit 0 ;;
esac
echo 'HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again.' >&2
exit 1
GHEOF
chmod +x "$GREAL_SEC"
GREAL_ORD="$TMP/gate-real-ordinary"
cat > "$GREAL_ORD" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*) printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684}}}'; exit 0 ;;
esac
echo 'HTTP 403: API rate limit exceeded for user ID 81560491.' >&2
exit 1
GHEOF
chmod +x "$GREAL_ORD"
# Lane A: a SECONDARY refusal writes the window and stamps the flag with its deadline.
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL_SEC" AGENT_GH_GATE_DIR="$GDIR2" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
if [ -s "$GDIR2/secondary.window" ]; then
  _sw="$(cat "$GDIR2/secondary.window" 2>/dev/null)"
  case "$_sw" in
    ''|*[!0-9]*) fail "(f)(vii) the secondary flag carries NO deadline ('$_sw') — a peer cannot tell which window it protects" ;;
    *) pass "(f)(vii) a secondary refusal stamps the flag with the deadline it protects ($_sw)" ;;
  esac
else
  fail "(f)(vii) a secondary refusal did not record its window kind at all"
fi
# Lane B: an ORDINARY refusal on the same box must NOT clear lane A's flag.
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL_ORD" AGENT_GH_GATE_DIR="$GDIR2" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
[ -s "$GDIR2/secondary.window" ] \
  && pass "  …and a PEER's ordinary refusal does not clear it (the longer secondary window stays protected)" \
  || fail "  …and a peer's ordinary refusal ERASED the secondary window — #1762 fail-open is back"
# …and while that flag is live, a healthy exempt read still cannot discharge the window.
: > "$GDIR2/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR2" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>"$TMP/contended.err"
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "  …and the live secondary window is still honoured by a healthy primary read (rc=75)" \
  || fail "  …and the live secondary window was DISCHARGED (rc=$_rc) — #1762 fail-open is back"
rm -f "$GDIR2"/cooldown.* "$GDIR2/secondary.window" 2>/dev/null
GDIR="$(gate_dir revalidate)"

# (f)(viii) ⛔ THE CONTENDED VERDICT MUST NOT BE READ AS A LIMIT ONE LAYER UP (finding 1). The rc=75
# note is written to STDERR, which `gh-limit.py` classifies: a LIMIT_PHRASES term with no HTTP status
# turns "I could not ask" into a 4-attempt retry plus a box-wide `last-limit` marker that blocks
# OTHER lanes. Pinned twice — the note's wording, AND classify()'s rc arm (so drift cannot recapture it).
SHIM_NOTE="$(grep -o 'gh-contended —[^"]*' "$SHIM" | head -1)"
case "$(printf '%s' "$SHIM_NOTE" | tr 'A-Z' 'a-z')" in
  *'rate limit'*|*'rate-limit'*|*'secondary rate'*|*'abuse detection'*)
    fail "(f)(viii) the rc=75 note CONTAINS a gh-limit.py LIMIT_PHRASE — the contended verdict will be re-read as a limit" ;;
  *gh-contended*)
    pass "(f)(viii) the rc=75 note carries no LIMIT_PHRASE (so it cannot be re-classified as a limit)" ;;
  *)
    fail "(f)(viii) the rc=75 note was not found where this arm looks for it ('$SHIM_NOTE')" ;;
esac
_GLC="$(python3 - "$ROOT/scripts/orchestrator-harness/gh-limit.py" "$TMP/contended.err" <<'PYEOF'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("gh_limit_under_test", sys.argv[1])
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
# ⛔ THE REAL STDERR OF A CONTENDED CALL, not a message written to make the arm pass. The shim
# flushes EVERY note it accumulated on the rc=75 path (`flush_notes 75`), and one of them is
# "the account is in a shared rate-limit window — waiting …" — so this stderr DOES carry a
# LIMIT_PHRASE however the contended note itself is worded. That is why the rc==75 arm is
# load-bearing and not belt-and-braces, and this arm proves the hazard is real before proving it
# is handled: `phrase=True` is asserted, so the arm cannot pass on a message that never had one.
err = open(sys.argv[2], "rb").read()
phrase = any(p in err.decode("utf-8", "replace").lower() for p in m.LIMIT_PHRASES)
contended = m.Result(75, b"", err)
control = m.Result(1, b"", err)
print("phrase=%s contended=%s control=%s" % (
    phrase,
    m.classify(contended, ["pr", "view", "1"], {}) is None,
    m.classify(control, ["pr", "view", "1"], {}) is not None))
PYEOF
)"
case "$_GLC" in
  'phrase=True contended=True control=True')
    pass "  …and the emitted stderr DOES carry a LIMIT_PHRASE, yet rc=75 is not a limit (a real 403 still is)" ;;
  *)
    fail "  …and the contended verdict is mishandled or the arm is inert: $_GLC" ;;
esac

rm -f "$GDIR"/cooldown.* "$GDIR/secondary.window" "$GDIR/retry-after.window" 2>/dev/null

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# (f)(ix)–(f)(x) — THE TWO DISCHARGES THE SECOND REVIEW ROUND FOUND STILL OPEN. Both were reported
# with a recorded decision behind them, and both are pinned BEHAVIOURALLY with an anti-inert
# control, so neither can pass for a gate that simply never discharges anything.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# (f)(ix) ⛔ A `retry-after` WINDOW IS THE SERVER'S OWN INSTRUCTION AND IS NEVER DISCHARGED. The
# header is also the documented way a secondary refusal announces itself without using the
# runbook's exact wording, and `/rate_limit` cannot see a secondary limit at all — so before this
# arm, a 300 s server-directed window was deleted by a 0.4 s read of a budget that does not predict
# it (`gh-limit.py:843-851` records the identical measured failure one layer up).
GDIR="$(gate_dir revalidate-retry-after)"
GREAL_RA="$TMP/gate-real-retry-after"
cat > "$GREAL_RA" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*)
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684},"graphql":{"limit":5000,"remaining":4976},"search":{"limit":30,"remaining":30}}}'
    exit 0 ;;
esac
echo 'HTTP 403: API rate limit exceeded for user ID 81560491. (retry-after: 300)' >&2
exit 1
GHEOF
chmod +x "$GREAL_RA"
# Lane A: the refusal's KIND is recorded. NO_WAIT so it returns at once instead of sleeping 300 s.
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL_RA" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_ra="$(cat "$GDIR/retry-after.window" 2>/dev/null)"
case "$_ra" in
  ''|*[!0-9]*) fail "(f)(ix) a retry-after refusal recorded NO window kind ('$_ra') — the discharge cannot know to refuse it" ;;
  *) pass "(f)(ix) a retry-after refusal stamps the window kind with the deadline it protects ($_ra)" ;;
esac
# Lane B: a HEALTHY exempt read must still HONOUR it.
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "  …and a healthy primary read HONOURS it (rc=75) — headroom does not contradict the server" \
  || fail "  …but a retry-after window was DISCHARGED on healthy buckets (rc=$_rc) — the server's own instruction was overruled"
grep -q 'DISCHARGED' "$GDIR/events.log" 2>/dev/null \
  && fail "  …and it was recorded as DISCHARGED" \
  || pass "  …and nothing was discharged"
# CONTROL: drop the kind flag AND the evidence record that describes the same refusal, and the SAME
# read DOES discharge — so the arm above cannot be satisfied by a revalidation that never fires.
# ⛔ EVERY RECORD, because one refusal writes THREE: the `retry-after.window` this arm asserts, the
# evidence record (`refusal.*` — refusing bucket, the deadline it implies, the account it names), and
# — since the class is decided from structured evidence (#3228 P1-b/P1-c) — `secondary.window`, which
# a `retry-after` WITHOUT an exhausted primary bucket now correctly also raises. Dropping only the
# first left the other two still saying "the server directed this window", so a control that clears
# half the evidence tests a premise the code no longer holds (the same lesson this arm learned once
# already, for two; the kind set grew to three).
ls "$GDIR"/refusal.* >/dev/null 2>&1 \
  || fail "(f)(ix) control is VACUOUS: no evidence record was written for the refusal it drops"
rm -f "$GDIR/retry-after.window" "$GDIR/secondary.window" "$GDIR"/refusal.*
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] \
  && pass "(f)(ix) control: the same healthy read DOES lift it once the kind flag is gone (rc=0)" \
  || fail "(f)(ix) control: the gate is inert — an ordinary window is no longer discharged (rc=$_rc)"

# (f)(x) ⛔ ONE EXEMPT READ AT A TIME, BOX-WIDE (finding 4). Without the single-flight lock the read
# fires exactly when a shared window is open — the contention peak — so N blocked lanes issue N
# concurrent requests, which is how a primary window is converted into the secondary concurrency
# limit the runbook says causes the fleet-wide outage. gh-limit.py:2941 takes this lock for the
# identical read: "the ONE gh request the layer issues unserialised … One invariant, no exemptions".
GDIR="$(gate_dir revalidate-single-flight)"
GREAL_SF="$TMP/gate-real-single-flight"; GSFC="$TMP/gate-sf-count"
cat > "$GREAL_SF" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*)
    n=$(cat "$GSFC" 2>/dev/null || echo 0); n=$(( n + 1 )); printf '%s' "$n" > "$GSFC"
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684},"graphql":{"limit":5000,"remaining":4976},"search":{"limit":30,"remaining":30}}}'
    exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$GREAL_SF"
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
sleep 30 &
_sfholder=$!
mkdir -p "$GDIR/revalidate.lock" && printf '%s\n' "$_sfholder" > "$GDIR/revalidate.lock/pid"
: > "$GSFC"; : > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_SF" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 GSFC="$GSFC" bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "(f)(x) a HELD single-flight lock honours the window instead of asking again (rc=75)" \
  || fail "(f)(x) a peer's single-flight lock was ignored (rc=$_rc) — the discharge is not serialised"
[ ! -s "$GSFC" ] \
  && pass "  …and NO second exempt read was issued while a peer held the lock (0 requests at the peak)" \
  || fail "  …but it issued $(cat "$GSFC" 2>/dev/null) exempt read(s) while a peer held the lock — the peak becomes a burst"
grep -q 'already re-deriving' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and says why, rather than honouring silently" \
  || fail "  …and the reason is silent: $(head -2 "$GDIR/events.log" 2>/dev/null | tr '\n' ' ')"
# CONTROL: release the lock and the SAME call issues exactly one read and proceeds.
rm -rf "$GDIR/revalidate.lock"; kill "$_sfholder" 2>/dev/null; wait "$_sfholder" 2>/dev/null
: > "$GSFC"; : > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_SF" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 GSFC="$GSFC" bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] && [ "$(cat "$GSFC" 2>/dev/null || echo 0)" -eq 1 ] \
  && pass "(f)(x) control: with the lock free the read IS issued (exactly 1) and the window is lifted (rc=0)" \
  || fail "(f)(x) control: free lock did not revalidate (rc=$_rc, reads=$(cat "$GSFC" 2>/dev/null || echo 0))"

rm -f "$GDIR"/cooldown.* "$GDIR/secondary.window" "$GDIR/retry-after.window" 2>/dev/null

# ══════════════════════════════════════════════════════════════════════════════════════════════
# (f)(xvi)–(f)(xx) — #3228's SECOND REVIEW, FINDINGS 1–4: THE CLASSIFIER IS EVIDENCE, NOT PROSE.
# ⛔ THE FIXTURE STRING IS VERBATIM FROM THE OPERATOR'S MEASUREMENT (2026-11-01, this box): the shim
# was refused `HTTP 403: API rate limit exceeded for user ID 81560491` while the SAME account and
# token (`gh api user` → daniel-ospina id=81560491) read `core: 4575/5000` from `gh api rate_limit`.
# That message contains neither `secondary rate limit` nor `abuse detection`, which is why a
# prose-grep classifier could not see the class and wrote a PRIMARY window for it. A fixture invented
# to suit the fix would prove nothing, so this one is the measured string itself.
# ══════════════════════════════════════════════════════════════════════════════════════════════
GDIR="$(gate_dir measured)"
MEASURED_MSG='HTTP 403: API rate limit exceeded for user ID 81560491'

# (f)(xvi) ⛔ THE WRITE SIDE, PINNED. No arm anywhere used to drive a refusal through the shim and
# assert what it RECORDED (`(f)(ii)` created `secondary.window` by hand), so deleting the whole
# classifier block left the suite green. Here the measured refusal goes through the real argv path
# and the arm asserts the evidence it must leave behind — bucket, no retry-after, not secondary, and
# WHICH ACCOUNT was refused.
GREAL_MEASURED="$TMP/gate-real-measured"
cat > "$GREAL_MEASURED" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *rate_limit*) printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4575},"graphql":{"limit":5000,"remaining":4988},"search":{"limit":30,"remaining":30}}}'; exit 0 ;;
esac
printf '%s\n' '$MEASURED_MSG' >&2
exit 1
GHEOF
chmod +x "$GREAL_MEASURED"
: > "$GDIR/events.log"
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL_MEASURED" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" pr view 1 >/dev/null 2>&1
_rc=$?
_evf="$(ls "$GDIR"/refusal.* 2>/dev/null | head -n 1)"
if [ -z "$_evf" ]; then
  fail "(f)(xvi) the measured 403 left NO evidence record — the refusal was classified with no evidence at all"
else
  _eb="$(sed -n 's/^bucket=//p' "$_evf")"; _er="$(sed -n 's/^retry_after_until=//p' "$_evf")"
  _es="$(sed -n 's/^secondary=//p' "$_evf")"; _eu="$(sed -n 's/^uid=//p' "$_evf")"
  [ "$_eb" = graphql ] \
    && pass "(f)(xvi) the measured 403 records the bucket the CALL targets (bucket=$_eb for \`pr view\`)" \
    || fail "(f)(xvi) the refusal evidence names the wrong bucket ('$_eb') — the log would send an operator to core"
  [ "$_es" = 0 ] \
    && pass "  …and it is NOT called secondary on absent prose (secondary=$_es) — the prose is corroboration, not the discriminator" \
    || fail "  …and a message with no secondary phrase was recorded as secondary ('$_es')"
  [ -z "$_er" ] \
    && pass "  …and no retry-after is invented (retry_after_until empty, as the measured message carries none)" \
    || fail "  …and a retry-after deadline was INVENTED ('$_er') — nothing would ever discharge it"
  [ "$_eu" = 81560491 ] \
    && pass "  …and it names the account that was refused (uid=$_eu), so a probe of another account cannot pose as its evidence" \
    || fail "  …and the refusing account was not recorded (uid='$_eu') — the credentialed identity is unverified"
  [ -s "$GDIR/secondary.window" ] \
    && fail "  …but a plain 403 also stamped the secondary flag — the flag is no longer a discriminator" \
    || pass "  …and no secondary flag was stamped (the flag still means what it says)"
fi

# (f)(xvii) ⛔ FINDING 1, THE HARM ITSELF. `gh` appends the server's `retry-after` to a refusal, and the
# API docs say not to retry before it elapses. This message carries NO secondary phrase, so it used
# to be written as a PRIMARY window, and the first waiting lane read a healthy `core` and DELETED it
# ~59 s before the deadline — releasing every lane at once. Lane 1 is refused (writes the window),
# lane 2 meets it with a perfectly healthy account: it must HONOUR it, not discharge it.
GDIR="$(gate_dir retry-after)"
GREAL_RA="$TMP/gate-real-retry-after"
cat > "$GREAL_RA" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *rate_limit*) printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4600},"graphql":{"limit":5000,"remaining":4900}}}'; exit 0 ;;
esac
printf '%s\n' '$MEASURED_MSG' >&2
printf '%s\n' '(retry-after: 30) (https://api.github.com/graphql)' >&2
exit 1
GHEOF
chmod +x "$GREAL_RA"
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL_RA" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" pr view 1 >/dev/null 2>&1
_rau="$(sed -n 's/^retry_after_until=//p' "$GDIR"/refusal.* 2>/dev/null | head -n 1)"
case "$_rau" in
  ''|*[!0-9]*) fail "(f)(xvii) the authoritative retry-after was not recorded ('$_rau') — the window it wrote is dischargeable again" ;;
  *) pass "(f)(xvii) a refusal carrying \`retry-after: 30\` records the deadline it implies (retry_after_until=$_rau)" ;;
esac
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_RA" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" pr view 1 >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "  …and a HEALTHY account does NOT re-derive it (rc=75): an authoritative retry-after is not contradicted by a quota read" \
  || fail "  …and the window was DISCHARGED (rc=$_rc) ~29 s before its retry-after expired — the exact fail-open of review finding 1"
grep -q 'DISCHARGED' "$GDIR/events.log" 2>/dev/null \
  && fail "  …and it was logged as DISCHARGED while an authoritative deadline was still running" \
  || pass "  …and nothing in the operator's log claims a discharge that did not happen"

# (f)(xviii) ⛔ FINDING 6's SECOND HALF: the burst arm (§13(e)) only stayed green because its fixture's
# `retry-after: 2` produced a 2000 ms window, BELOW the fixed REVALIDATE_MIN_MS=3000 — so the probe
# never ran and "exactly 1 refusal" was an accident of the fixture. At a real 30 s window with a
# healthy probe, N lanes used to probe → discharge → re-refuse. Here 5 lanes meet that window: none
# may be admitted, so there is still exactly ONE refusal — the one that wrote it.
INJECT_GATE="$GDIR"
GHCOUNT="$TMP/gate-retry-after-count"; rm -f "$GHCOUNT"
GREAL_COUNT="$TMP/gate-real-count"
cat > "$GREAL_COUNT" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*) printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4600},"graphql":{"limit":5000,"remaining":4900}}}'; exit 0 ;;
esac
printf 'x' >> "${GHCOUNT:?}"
exit 1
GHEOF
chmod +x "$GREAL_COUNT"
for _l in 1 2 3 4 5; do
  AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_COUNT" AGENT_GH_GATE_DIR="$INJECT_GATE" \
    AGENT_GH_GATE_INTERVAL_MS=0 GHCOUNT="$GHCOUNT" \
    bash "$SHIM" pr view 1 >/dev/null 2>&1 &
done
wait
_admitted=$(cat "$GHCOUNT" 2>/dev/null | tr -d '\n' | wc -c | tr -d ' ')
[ "$_admitted" -eq 0 ] \
  && pass "(f)(xviii) 5 lanes meet a 30 s retry-after window with a healthy probe → 0 admitted (still exactly 1 refusal)" \
  || fail "(f)(xviii) $_admitted of 5 lanes were ADMITTED through an authoritative window — that is the N-refusals-for-1 burst"

# (f)(xix) ⛔ FINDING 4: the discharge must not delete a window it never read. A peer's refusal
# arriving DURING the exempt read writes a fresh `cooldown.<later>`; the old `rm -f cooldown.*`
# deleted it while it was still authoritative, and the peer's flag outlived the window it protected.
GDIR="$(gate_dir compare-delete)"
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
printf 'until=%s\nbucket=core\nretry_after_until=\nsecondary=0\nprimary_hdr=0\nuid=\n' "$_until" \
  > "$GDIR/refusal.$_until.$$"
INJECTED="$GDIR/cooldown.injected.$$"
GREAL_INJECT="$TMP/gate-real-inject"
cat > "$GREAL_INJECT" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *rate_limit*)
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4600},"graphql":{"limit":5000,"remaining":4900}}}'
    printf '%s\n' "\${INJECT_UNTIL:-1}" > "\${INJECT_FILE:?}"
    exit 0 ;;
esac
exit 0
GHEOF
chmod +x "$GREAL_INJECT"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_INJECT" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 INJECT_FILE="$INJECTED" INJECT_UNTIL="$(( $(date +%s) * 1000 + 120000 ))" \
  bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
grep -q 'DISCHARGED' "$GDIR/events.log" 2>/dev/null \
  && pass "(f)(xix) the window this call READ is discharged — the fix still lifts a stale window (rc=$_rc)" \
  || fail "(f)(xix) the read window was not discharged (rc=$_rc) — the compare-and-delete over-blocks"
[ -e "$INJECTED" ] \
  && pass "  …and the window that arrived DURING the probe is still there — never deleted unread" \
  || fail "  …and a peer's FRESH refusal window was deleted by a read that never saw it (finding 4)"
grep -q 'refusing bucket:' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and the discharge note NAMES the bucket that refused (no 'every bucket available' claim)" \
  || fail "  …and the discharge note does not state which bucket refused"
grep -q 'every bucket' "$GDIR/events.log" 2>/dev/null \
  && fail "  …and the operator's log still claims 'every bucket' — a statement the code never measured (finding 2)" \
  || pass "  …and nothing in the log claims a measurement that was never taken"

# (f)(xx) ⛔ FINDING 3: a record with no window is the defect this change exists to delete. The
# evidence must die with the window it explains — pruned by TIME, never by a later writer's opinion.
GDIR="$(gate_dir evidence-ttl)"
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
printf 'until=1\nbucket=core\nretry_after_until=99999999999999\nsecondary=0\nprimary_hdr=0\nuid=\n' \
  > "$GDIR/refusal.1.$$"
: > "$GDIR/refusal.2.$$"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
ls "$GDIR"/refusal.* >/dev/null 2>&1 \
  && fail "(f)(xx) an expired evidence record survives its window — a state with no window is back (finding 3)" \
  || pass "(f)(xx) evidence records are pruned once their window has expired (no stale kind, no stale deadline)"

# (f)(xxi)–(f)(xxii) — #3228's THIRD REVIEW ROUND: THE TWO RESIDUALS THE ARMS ABOVE CANNOT SEE.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# (f)(xxi) ⛔ A DISCHARGE MUST NOT TOUCH THE CALLER'S STDOUT — AND THE NOTE MUST NAME THE FIGURE.
# `rate_limit_verdict` PRINTS its `OK lowest=…` line; uncaptured it landed AHEAD OF THE REAL ANSWER,
# so every consumer that parses the shim's bytes broke on a call that SUCCEEDED (`gh-rest/gh` jq's
# the output). EVERY discharge arm above redirects `>/dev/null`, which is exactly why none of them
# caught it — so this one asserts the ANSWER, not just the exit code.
GDIR="$(gate_dir revalidate-stdout)"
GREAL_OUT="$TMP/gate-real-stdout"
cat > "$GREAL_OUT" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*)
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684},"graphql":{"limit":5000,"remaining":4976},"search":{"limit":30,"remaining":30}}}'
    exit 0 ;;
esac
printf '%s\n' '{"number":1,"title":"real answer"}'
GHEOF
chmod +x "$GREAL_OUT"
# baseline: no window open — the pristine answer this call prints on its own.
_out_clean="$(AGENT_GH_REAL="$GREAL_OUT" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  bash "$SHIM" api user 2>/dev/null)"
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
: > "$GDIR/events.log"
_out_w="$(AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_OUT" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user 2>/dev/null)"
_rc=$?
[ "$_rc" -eq 0 ] \
  && pass "(f)(xxi) a discharged call still succeeds (rc=0)" \
  || fail "(f)(xxi) the discharge did not happen at all (rc=$_rc)"
[ "$_out_w" = "$_out_clean" ] && [ -n "$_out_clean" ] \
  && pass "  …and the caller's STDOUT is byte-identical with and without a discharge" \
  || fail "  …but the discharge leaked into the caller's stdout: '$(printf '%s' "$_out_w" | head -c 120)'"
grep -q 'lowest remaining 4684/5000' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and the note names the bucket figure it actually READ" \
  || fail "  …but the note does not name the figure: '$(head -1 "$GDIR/events.log" 2>/dev/null)'"

# (f)(xxii) ⛔ A SHORTER SAME-KIND REFUSAL MUST NOT SHRINK THE KIND FLAG. Deadlines are monotonic
# maxima across `cooldown.*`, so a 5 s refusal overwriting a 300 s one expires the flag at t+5 s
# while the governing window runs to t+300 s. For a refusal with NO `retry-after` header
# `REFUSAL_RETRY_S` is 0 and the evidence record does not gate it either, so the only guard left is
# `secondary_live` — and a shrunk flag leaves 295 s dischargeable by a primary read (#1762 again).
GDIR="$(gate_dir revalidate-kind-max)"
GREAL_KIND="$TMP/gate-real-kind"
cat > "$GREAL_KIND" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*) printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684}}}'; exit 0 ;;
esac
_hdr="$(cat "$KIND_RETRY" 2>/dev/null || echo 60)"
echo "HTTP 403: You have exceeded a secondary rate limit. (retry-after: $_hdr)" >&2
exit 1
GHEOF
chmod +x "$GREAL_KIND"
KIND_RETRY="$TMP/kind-retry"
printf '%s' 300 > "$KIND_RETRY"
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL_KIND" AGENT_GH_GATE_DIR="$GDIR" KIND_RETRY="$KIND_RETRY" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_long="$(cat "$GDIR/secondary.window" 2>/dev/null)"
printf '%s' 5 > "$KIND_RETRY"
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL_KIND" AGENT_GH_GATE_DIR="$GDIR" KIND_RETRY="$KIND_RETRY" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_short="$(cat "$GDIR/secondary.window" 2>/dev/null)"
case "${_long:-x}${_short:-x}" in
  *[!0-9]*) fail "(f)(xxii) the kind flag is not a deadline ('$_long' then '$_short')" ;;
  *) [ "$_short" -ge "$_long" ] \
      && pass "(f)(xxii) a shorter same-kind refusal does NOT shrink the flag ($_long → $_short)" \
      || fail "(f)(xxii) the flag SHRANK to a shorter same-kind deadline ($_long → $_short) — a longer governing window is left dischargeable" ;;
esac

rm -f "$GDIR"/cooldown.* "$GDIR/secondary.window" "$GDIR"/refusal.* 2>/dev/null

# (f)(xxiii)–(f)(xxvii) — #3228's FOURTH REVIEW ROUND. Each of these was RED on the head it was
# written against; each names the defect it pins rather than the fix it hopes for.
# ═══════════════════════════════════════════════════════════════════════════════════════════════
# (f)(xxiii) ⛔ THE VERDICT MUST READ A BODY SHAPED LIKE THE REAL ONE. GitHub's `/rate_limit`
# reports a long tail of buckets whose WHOLE limit is 100 (`source_import`, `dependency_snapshots`,
# `dependency_sbom`). With the floor branch written as `lim>=floor_n and rem<=floor_n`, a healthy
# account made `source_import` 100/100 permanently "low", so EVERY window was honoured and the
# revalidation could never fire — the gate was INERT on a real box while every fixture (three
# buckets: core/graphql/search) stayed green. MEASURED on the live account: floor 100 against the
# real body printed `LOW source_import 100/100`.
GDIR="$(gate_dir revalidate-real-shape)"
GREAL_REAL_SHAPE="$TMP/gate-real-real-shape"
cat > "$GREAL_REAL_SHAPE" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*)
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684},"graphql":{"limit":5000,"remaining":4976},"search":{"limit":30,"remaining":30},"source_import":{"limit":100,"remaining":100},"dependency_snapshots":{"limit":100,"remaining":100},"dependency_sbom":{"limit":100,"remaining":100},"code_search":{"limit":10,"remaining":10},"audit_log_streaming":{"limit":15,"remaining":15}}}'
    exit 0 ;;
esac
printf '%s\n' '{"number":1,"title":"real answer"}'
GHEOF
chmod +x "$GREAL_REAL_SHAPE"
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_REAL_SHAPE" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] \
  && pass "(f)(xxiii) a REAL-shaped healthy body (limit-100 buckets at 100/100) is DISCHARGED (rc=0)" \
  || fail "(f)(xxiii) the gate is INERT on a real /rate_limit body — a limit-100 bucket at 100/100 reads as low (rc=$_rc)"

# (f)(xxiv) ⛔ THE CORROBORATING NOTE MUST NAME THE BUCKET. The `LOW` verdict was returned WITHOUT
# being printed, so the caller's `sed -n 's/^LOW //p'` produced an empty figure and the operator's
# log read `(a bucket is low: )` — a claim with nothing in it, from the one surface a human debugs
# with. This body has a limit-100 bucket GENUINELY exhausted (0 left), which must stay low.
GDIR="$(gate_dir revalidate-low-names)"
GREAL_LOW_NAME="$TMP/gate-real-low-names"
cat > "$GREAL_LOW_NAME" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*)
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684},"graphql":{"limit":5000,"remaining":4976},"source_import":{"limit":100,"remaining":0}}}'
    exit 0 ;;
esac
printf '%s\n' '{"number":1}'
GHEOF
chmod +x "$GREAL_LOW_NAME"
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_LOW_NAME" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "(f)(xxiv) a limit-100 bucket genuinely EXHAUSTED (0 left) still corroborates (rc=75)" \
  || fail "(f)(xxiv) an exhausted small bucket was discharged (rc=$_rc)"
grep -q 'a bucket is low: source_import 0/100' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and the note NAMES the bucket it read (not '(a bucket is low: )')" \
  || fail "  …but the note does not name the bucket: '$(grep 'bucket is low' "$GDIR/events.log" 2>/dev/null | head -1)'"

# (f)(xxv) ⛔ A BARE `HTTP 429` IS A SECONDARY REFUSAL. `rate_limited` accepts it (so a window is
# written), but the KIND was decided by three prose phrases that a bare 429 does not contain — so the
# window carried NO protecting flag and a healthy primary read discharged it, releasing every lane
# into the live burst limit (`docs/ops/gh-rate-limits.md`: "429 → secondary").
GDIR="$(gate_dir revalidate-429)"
GREAL_429="$TMP/gate-real-429"
cat > "$GREAL_429" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*) printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684},"graphql":{"limit":5000,"remaining":4976}}}'; exit 0 ;;
esac
if [ -e "$RA429" ]; then printf '%s\n' '{"number":1}'; exit 0; fi
printf '%s' 1 > "$RA429"
echo 'HTTP 429: Too Many Requests' >&2
exit 1
GHEOF
chmod +x "$GREAL_429"
RA429="$TMP/ra429-flag"
rm -f "$RA429"
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL_429" AGENT_GH_GATE_DIR="$GDIR" RA429="$RA429" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
[ -s "$GDIR/secondary.window" ] \
  && pass "(f)(xxv) a bare 429 writes a PROTECTED (secondary) window" \
  || fail "(f)(xxv) a bare 429 wrote an UNPROTECTED window — the kind classifier does not know 429"
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_429" AGENT_GH_GATE_DIR="$GDIR" RA429="$RA429" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "  …and a HEALTHY primary read does NOT discharge it (rc=75) — the 429 burst stays honoured" \
  || fail "  …and a healthy read DISCHARGED a 429 window (rc=$_rc) — every lane released into the burst limit"

# (f)(xxvi) ⛔ A `retry-after.window` ARRIVING DURING THE PROBE MUST SURVIVE — the same guarantee
# `(f)(xix)` pins for a `cooldown.*` file, for the OTHER undisgargeable kind. `retry_after_live` was
# read BEFORE the lock and only `secondary_live` was re-read after the probe, so a peer whose
# `cooldown.<until>` was already in the snapshot and whose flag landed during the 5 s read had its
# server-mandated deadline deleted as an ordinary stale window.
GDIR="$(gate_dir retry-after-during-probe)"
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
printf 'until=%s\nbucket=core\nretry_after_until=\nsecondary=0\nprimary_hdr=0\nuid=\n' "$_until" \
  > "$GDIR/refusal.$_until.$$"
GREAL_RA_DURING="$TMP/gate-real-ra-during"
cat > "$GREAL_RA_DURING" <<GHEOF
#!/usr/bin/env bash
case "\$*" in
  *rate_limit*)
    # The peer finishes its ARM-1 write sequence while OUR exempt read is in flight.
    printf '%s' "$_until" > "$GDIR/retry-after.window"
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684},"graphql":{"limit":5000,"remaining":4976}}}'
    exit 0 ;;
esac
printf '%s\n' '{"number":1}'
GHEOF
chmod +x "$GREAL_RA_DURING"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_RA_DURING" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "(f)(xxvi) a retry-after window that arrived DURING the probe is HONOURED (rc=75)" \
  || fail "(f)(xxvi) a retry-after window arriving mid-probe was DISCHARGED (rc=$_rc) — the server's deadline was overruled"
[ -e "$GDIR/cooldown.$_until.$$" ] \
  && pass "  …and the cooldown it protects was not deleted" \
  || fail "  …and the peer's cooldown was deleted by a read that never saw its kind"

# (f)(xxvii) ⛔ THE EVIDENCE RECORD IS DEFENCE IN DEPTH, NOT DECORATION. `refusal_evidence_live`
# wrote `secondary=` and NEVER READ IT, so a writer killed between `cooldown.<until>` and the
# `secondary.window` flag left a burst window dischargeable. Here the record alone says secondary.
GDIR="$(gate_dir evidence-secondary)"
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
printf 'until=%s\nbucket=graphql\nretry_after_until=\nsecondary=1\nprimary_hdr=0\nuid=81560491\n' "$_until" \
  > "$GDIR/refusal.$_until.$$"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 75 ] \
  && pass "(f)(xxvii) a secondary EVIDENCE RECORD with no flag still protects the window (rc=75)" \
  || fail "(f)(xxvii) a secondary evidence record was ignored (rc=$_rc) — the field is written and never read"
grep -q 'SECONDARY' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and the operator's log says WHY (secondary/abuse)" \
  || fail "  …but the reason is silent: '$(head -1 "$GDIR/events.log" 2>/dev/null)'"

# ═══════════════════════════════════════════════════════════════════════════════════════════════
# (f)(xxviii)–(f)(xxxiii) — #3228's FIFTH REVIEW ROUND: THE THREE P1s AN INDEPENDENT REVIEWER
# MEASURED ON THIS BRANCH'S OWN HEAD. P1-a and P1-c MASKED EACH OTHER: a broken floor arithmetic hid
# behind a fixture that never reached the documented default, and a refusal shape the shim INVENTED
# hid the one GitHub actually returns. Each RED arm below was run against `6599f502f` and failed
# there; the comment states what it printed.
#
# (f)(xxviii) ⛔ P1-a: THE FLOOR BRANCH MUST NOT BE INERT **AT ITS DOCUMENTED DEFAULT**. The previous
# predicate was `lim>floor_n and rem<=floor_n`, so `floor=100` called a bucket holding 100 of 101
# requests LOW — and 100 IS the documented default, so on any body carrying such a bucket (GitHub's
# `/rate_limit` really does report `source_import`/`dependency_snapshots`/`dependency_sbom` with
# limits in this range) EVERY window was honoured and the discharge could never fire. 
# ⛔ THIS ARM SETS NO FLOOR. A fixture value chosen to make the arm pass would hide the defect one
# request further on — which is exactly how the previous two cuts of this branch looked green.
# MEASURED on `6599f502f`: rc=75 (the window was HONOURED, i.e. the discharge never fired).
GDIR="$(gate_dir revalidate-floor-default)"
GREAL_101="$TMP/gate-real-floor-default"
cat > "$GREAL_101" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*)
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4684},"graphql":{"limit":5000,"remaining":4976},"search":{"limit":30,"remaining":30},"source_import":{"limit":101,"remaining":100},"dependency_snapshots":{"limit":100,"remaining":100},"dependency_sbom":{"limit":100,"remaining":100},"code_search":{"limit":10,"remaining":10}}}'
    exit 0 ;;
esac
printf '%s\n' '{"number":1}'
GHEOF
chmod +x "$GREAL_101"
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
: > "$GDIR/events.log"
# NOTE: no AGENT_GH_GATE_REVALIDATE_FLOOR here — the DEFAULT is what is under test.
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_101" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] \
  && pass "(f)(xxviii) P1-a: at the DOCUMENTED DEFAULT floor, one-request-of-headroom (source_import 100/101) is DISCHARGED (rc=0)" \
  || fail "(f)(xxviii) P1-a: the discharge is INERT at its own documented default — source_import 100/101 reads as low (rc=$_rc)"

# (f)(xxix) CONTROL, not a RED arm (it is green on the old head too): the fix must not be re-openable
# by the ENV. `rate_limit_verdict` claimed in prose that no floor value could call a healthy account
# low; a prose claim with no arm behind it is how this branch shipped P1-a. A floor far above every
# bucket must still discharge a healthy account.
_until=$(( $(date +%s) * 1000 + 60000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_GATE_REVALIDATE_FLOOR=999999 AGENT_GH_REAL="$GREAL_101" \
  AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] \
  && pass "(f)(xxix) a POISONED floor (999999) still cannot call a healthy account low (rc=0)" \
  || fail "(f)(xxix) a poisoned AGENT_GH_GATE_REVALIDATE_FLOOR made the gate inert (rc=$_rc)"

# (f)(xxx) ⛔ P1-c: THE REFUSAL SHAPE THE SHIM COVERED WAS ONE IT INVENTED. GitHub answers BOTH limits
# with the SAME sentence — `API rate limit exceeded for user ID <id>` — and the shim's prose grep keyed
# on words that appear in NEITHER (`secondary rate limit`, `abuse detection`) or only in a variant it
# assumed (`api rate limit already exceeded`). The measured secondary 403 on this box arrived while
# the primary budget read 4902/5000, from `/actions/workflows?per_page=100` — the CLI's FIRST call, so
# every `gh run list` / `gh run view` was refused while `gh api` worked. The discriminator is the
# `x-ratelimit-remaining` VALUE, not the wording. This fixture is that refusal, byte-for-byte in the
# fields that matter; MEASURED on `6599f502f`: the record said `secondary=0` and NO `secondary.window`
# was written (the one protecting flag came from `retry-after`, so the kind — the thing that survives
# a deadline — was wrong).
GDIR="$(gate_dir real-secondary-shape)"
GREAL_SEC403="$TMP/gate-real-secondary-403"
cat > "$GREAL_SEC403" <<'GHEOF'
#!/usr/bin/env bash
if [ -e "$RA403" ]; then printf '%s\n' '{"total_count":0}'; exit 0; fi
printf '%s' 1 > "$RA403"
printf '%s\n' 'HTTP 403: API rate limit exceeded for user ID 81560491 (https://api.github.com/actions/workflows?per_page=100)' \
  'retry-after: 60' 'x-ratelimit-limit: 5000' 'x-ratelimit-remaining: 4902' 'x-ratelimit-reset: 1762100000' >&2
exit 1
GHEOF
chmod +x "$GREAL_SEC403"
RA403="$TMP/ra403-flag"; rm -f "$RA403"
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL_SEC403" AGENT_GH_GATE_DIR="$GDIR" RA403="$RA403" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" run list >/dev/null 2>&1
_rec="$(grep -h '^secondary=' "$GDIR"/refusal.* 2>/dev/null | head -1)"
[ "$_rec" = "secondary=1" ] \
  && pass "(f)(xxx) P1-c: the REAL secondary 403 (healthy remaining + retry-after) is recorded as secondary=1" \
  || fail "(f)(xxx) P1-c: the REAL secondary 403 was recorded as '${_rec:-<no record>}' — the classifier cannot see the shape GitHub actually sends"
[ -s "$GDIR/secondary.window" ] \
  && pass "  …and it writes the protecting secondary.window flag" \
  || fail "  …and NO secondary.window was written (the kind survives only as a retry-after deadline)"
grep -h '^bucket=' "$GDIR"/refusal.* 2>/dev/null | grep -qx 'bucket=core' \
  && pass "  …and it names the bucket the refusing URL went to (/actions/workflows → core)" \
  || fail "  …but the recorded bucket is '$(grep -h '^bucket=' "$GDIR"/refusal.* 2>/dev/null | head -1)'"

# (f)(xxxi) THE ANTI-OVER-CORRECTION CONTROL. The fix must not turn EVERY 403 into a secondary one —
# that would make every window undisgargeable for 60 s and re-create the outage from the other side.
# The PRIMARY shape is the SAME sentence with `x-ratelimit-remaining: 0` and no `retry-after`; it must
# classify PRIMARY and must be DISCHARGED by a later healthy read. Green on the old head too (that was
# the only shape the old code got right) — it exists to keep (f)(xxx) honest.
GDIR="$(gate_dir real-primary-shape)"
GREAL_PRI403="$TMP/gate-real-primary-403"
cat > "$GREAL_PRI403" <<'GHEOF'
#!/usr/bin/env bash
case "$*" in
  *rate_limit*)
    printf '%s\n' '{"resources":{"core":{"limit":5000,"remaining":4800},"graphql":{"limit":5000,"remaining":4976}}}'
    exit 0 ;;
esac
if [ -e "$RAPRI" ]; then printf '%s\n' '{"total_count":0}'; exit 0; fi
printf '%s' 1 > "$RAPRI"
printf '%s\n' 'HTTP 403: API rate limit exceeded for user ID 81560491 (https://api.github.com/repos/o/r/pulls)' \
  'x-ratelimit-limit: 5000' 'x-ratelimit-remaining: 0' 'x-ratelimit-reset: 1762100000' >&2
exit 1
GHEOF
chmod +x "$GREAL_PRI403"
RAPRI="$TMP/rapri-flag"; rm -f "$RAPRI"
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL_PRI403" AGENT_GH_GATE_DIR="$GDIR" RAPRI="$RAPRI" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" run list >/dev/null 2>&1
_rec="$(grep -h '^secondary=' "$GDIR"/refusal.* 2>/dev/null | head -1)"
[ "$_rec" = "secondary=0" ] \
  && pass "(f)(xxxi) the SAME sentence with x-ratelimit-remaining: 0 is recorded as primary (secondary=0)" \
  || fail "(f)(xxxi) a PRIMARY 403 was classified '${_rec:-<no record>}' — every window would become undisgargeable"
[ -s "$GDIR/secondary.window" ] \
  && fail "  …but it wrote a secondary.window — a primary refusal was misclassified" \
  || pass "  …and no secondary.window flag was written"
# …and the primary window IS dischargeable by a healthy read: the other half of the control.
RAPRI="$TMP/rapri-flag2"; rm -f "$RAPRI"
: > "$GDIR/events.log"
AGENT_GH_GATE_WAIT_BUDGET=1 AGENT_GH_REAL="$GREAL_PRI403" AGENT_GH_GATE_DIR="$GDIR" RAPRI="$RAPRI" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" run list >/dev/null 2>&1
_rc=$?
[ "$_rc" -eq 0 ] \
  && pass "  …and a healthy /rate_limit read DISCHARGES it (rc=0) — the gate is not inert in the other direction" \
  || fail "  …but a healthy read did NOT discharge a primary window (rc=$_rc)"

# (f)(xxxii) ⛔ P1-b: THE STRUCTURED FIELD DECIDES, THE PROSE IS THE FALLBACK. `x-ratelimit-remaining`
# was parsed, persisted as `primary_hdr=` and READ BY NOTHING, while the class was re-decided by a
# prose `grep` — twice (once in `refusal_evidence`, again at the call site), so the record and the
# flag could disagree. This fixture makes the two disagree ON PURPOSE: the wording says abuse, the
# header says a primary bucket is exhausted. The header must win. (Safety is unchanged either way:
# `remaining: 0` is low by the 10% rule, so the window stays honoured — the SUBJECT here is the
# recorded class, which is what a later reader and the operator's log act on.)
GDIR="$(gate_dir structured-beats-prose)"
GREAL_LIAR="$TMP/gate-real-liar"
cat > "$GREAL_LIAR" <<'GHEOF'
#!/usr/bin/env bash
if [ -e "$RALIAR" ]; then printf '%s\n' '{"total_count":0}'; exit 0; fi
printf '%s' 1 > "$RALIAR"
printf '%s\n' 'HTTP 403: You have exceeded a secondary rate limit. Please wait a few minutes before you try again. (https://api.github.com/repos/o/r/pulls)' \
  'x-ratelimit-limit: 5000' 'x-ratelimit-remaining: 0' 'x-ratelimit-reset: 1762100000' >&2
exit 1
GHEOF
chmod +x "$GREAL_LIAR"
RALIAR="$TMP/raliar-flag"; rm -f "$RALIAR"
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL_LIAR" AGENT_GH_GATE_DIR="$GDIR" RALIAR="$RALIAR" \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" run list >/dev/null 2>&1
_rec="$(grep -h '^secondary=' "$GDIR"/refusal.* 2>/dev/null | head -1)"
_hdr="$(grep -h '^primary_hdr=' "$GDIR"/refusal.* 2>/dev/null | head -1)"
[ "$_hdr" = "primary_hdr=1" ] \
  && pass "(f)(xxxii) P1-b: the structured field is READ and persisted (primary_hdr=1)" \
  || fail "(f)(xxxii) P1-b: the structured field was not recorded ('${_hdr:-<none>}')"
[ "$_rec" = "secondary=0" ] \
  && pass "  …and it BEATS the prose: 'secondary rate limit' wording + remaining:0 classifies PRIMARY" \
  || fail "  …but the PROSE decided the class ('${_rec:-<none>}') — the machine-readable evidence is decoration"

# (f)(xxxiii) ⛔ THE GOLDEN ARM. This shim sits on the hot path of EVERY `gh` call in the fleet, so a
# NORMAL (non-rate-limited) invocation must be byte-unchanged: same argv to the real gh, same stdout
# bytes, same stderr bytes, same exit code. A gate that reorders stderr, appends a banner or exits
# differently on the common path breaks every caller that parses output — `gh-rest/gh` merges `2>&1`
# and parses it as JSON, so a single stray byte is a JSONDecodeError on a good answer.
GDIR="$(gate_dir golden)"
GOLD="$TMP/gate-golden-real"; GCALLS="$TMP/gate-golden-calls"
cat > "$GOLD" <<GHEOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$GCALLS"
printf '{\n  "number": 1,\n  "title": "a normal answer"\n}\n'
printf 'a warning gh itself printed\n' >&2
exit 0
GHEOF
chmod +x "$GOLD"
: > "$GCALLS"
"$GOLD" api repos/o/r/pulls/1 --jq .number >"$TMP/golden.raw.out" 2>"$TMP/golden.raw.err"; _raw_rc=$?
_raw_argv="$(cat "$GCALLS")"
: > "$GCALLS"
AGENT_GH_REAL="$GOLD" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 GCALLS="$GCALLS" \
  bash "$SHIM" api repos/o/r/pulls/1 --jq .number >"$TMP/golden.shim.out" 2>"$TMP/golden.shim.err"; _shim_rc=$?
[ "$_shim_rc" -eq "$_raw_rc" ] \
  && pass "(f)(xxxiii) GOLDEN: a normal invocation returns the SAME exit code ($_shim_rc)" \
  || fail "(f)(xxxiii) GOLDEN: exit code changed ($_raw_rc → $_shim_rc)"
cmp -s "$TMP/golden.raw.out" "$TMP/golden.shim.out" \
  && pass "  …the SAME stdout bytes" \
  || fail "  …stdout CHANGED: $(diff <(od -c "$TMP/golden.raw.out") <(od -c "$TMP/golden.shim.out") 2>&1 | head -4 | tr '\n' ' ')"
cmp -s "$TMP/golden.raw.err" "$TMP/golden.shim.err" \
  && pass "  …the SAME stderr bytes (nothing prepended, nothing reordered)" \
  || fail "  …stderr CHANGED: $(diff <(od -c "$TMP/golden.raw.err") <(od -c "$TMP/golden.shim.err") 2>&1 | head -4 | tr '\n' ' ')"
[ "$(cat "$GCALLS")" = "$_raw_argv" ] \
  && pass "  …and the real gh received the ORIGINAL argv unchanged ('$_raw_argv')" \
  || fail "  …argv CHANGED: '$_raw_argv' → '$(cat "$GCALLS" | tr '\n' '|')'"

GDIR="$(gate_dir revalidate)"
# (g) A NON-rate-limit 403 IS NOT RETRIED. A permissions failure is not a burst, and
#     retrying a mutating command would run it twice.
GDIR="$(gate_dir perm403)"; GCOUNT="$TMP/gate-403-count"; rm -f "$GCOUNT"
GREAL="$TMP/gate-real-403"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
n=$(cat "$GCOUNT" 2>/dev/null || echo 0); n=$(( n + 1 )); printf '%s' "$n" > "$GCOUNT"
echo "HTTP 403: Resource not accessible by integration (https://api.github.com/x)" >&2
exit 1
GHEOF
chmod +x "$GREAL"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  GCOUNT="$GCOUNT" \
  bash "$SHIM" pr create --title x --body y >/dev/null 2>"$TMP/gate-403-err"; rc=$?
if [ "$rc" -ne 0 ] && [ "$(cat "$GCOUNT")" -eq 1 ]; then
  pass "a permissions 403 → refused, forwarded, and NOT retried (1 attempt, rc=$rc)"
else
  fail "a permissions 403 was retried or swallowed (rc=$rc attempts=$(cat "$GCOUNT" 2>/dev/null))"
fi
grep -q 'Resource not accessible' "$TMP/gate-403-err" \
  && pass "  …and gh's own message still reaches the caller" \
  || fail "  …but the real error text was lost"

# (h) A RATE-LIMITED **MUTATION** IS RETRIED AFTER BACKOFF, NOT TERMINAL (#1910).
#     The measured incident (issue #1910, PR #1934) failed at the MUTATION — `gh pr merge` —
#     with `GraphQL: API rate limit already exceeded`, and the rail surfaced that as a
#     terminal `merge_unreadable` / `head_unreadable`. The rail's refusal now says a
#     rate-limited call is RETRYABLE (`tests/admin-merge` §13h); THIS is the mechanism that
#     makes that true — `run_paced` retries EVERY paced call on a rate-limit refusal,
#     mutations included, while a permissions 403 is still never retried — arm (g).
#     ⛔ PINNED AT THE MUTATION, not at a read: a change that restricted retries to reads
#     would leave (c)/(d)/(g) green and turn a rate-limited merge back into a terminal
#     failure, which is the exact shape the incident cost.
GDIR="$(gate_dir mutretry)"; GCOUNT="$TMP/gate-mut-count"; GTIMES="$TMP/gate-mut-times"
GARGV="$TMP/gate-mut-argv"
rm -f "$GCOUNT"; : > "$GTIMES"; : > "$GARGV"
GREAL="$TMP/gate-real-mut"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
n=$(cat "$GCOUNT" 2>/dev/null || echo 0); n=$(( n + 1 )); printf '%s' "$n" > "$GCOUNT"
printf '%s\n' "$*" >> "$GARGV"
date +%s >> "$GTIMES"
if [ "$n" -eq 1 ]; then
  echo "GraphQL: API rate limit already exceeded for user ID 81560491. (retry-after: 1)" >&2
  exit 1
fi
printf 'merged\n'
exit 0
GHEOF
chmod +x "$GREAL"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  GCOUNT="$GCOUNT" GTIMES="$GTIMES" GARGV="$GARGV" \
  bash "$SHIM" pr merge 123 --squash >"$TMP/gate-mut-out" 2>"$TMP/gate-mut-err"; rc=$?
m1=$(sed -n '1p' "$GTIMES"); m2=$(sed -n '2p' "$GTIMES")
if [ "$rc" -eq 0 ] && [ "$(cat "$GCOUNT" 2>/dev/null || echo 0)" -eq 2 ] && [ -n "$m2" ] \
   && [ $(( m2 - m1 )) -ge 1 ]; then
  pass "a rate-limited MERGE MUTATION is retried after backoff (${m1}→${m2}), then succeeds"
else
  fail "a rate-limited mutation was treated as TERMINAL (rc=$rc attempts=$(cat "$GCOUNT" 2>/dev/null || echo 0))"
fi
[ "$(wc -l < "$GARGV")" -eq 2 ] && [ "$(sort -u "$GARGV" | wc -l)" -eq 1 ] \
  && pass "  …and the retry re-sends the ORIGINAL argv unchanged (2 attempts, one argv)" \
  || fail "  …but the calls were not one argv sent twice: $(wc -l < "$GARGV") attempt(s) / $(sort -u "$GARGV" | wc -l) distinct argv: $(tr '\n' '|' < "$GARGV")"
grep -q 'merged' "$TMP/gate-mut-out" \
  && pass "  …and the retried attempt's stdout is what the caller sees" \
  || fail "  …but the retried attempt's stdout was lost: $(cat "$TMP/gate-mut-out")"
# The wait is announced where cycle-1 put it — the gate's OWN log, never a successful call's
# stderr (`gh-rest/gh` parses `2>&1` as JSON, so a note there is a JSONDecodeError on the
# caller's good answer). Assert BOTH directions, as §13(c)/(d) do.
grep -q 'waiting 1s' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and the wait it took is recorded in the gate's events.log" \
  || fail "  …but the retry window was never announced: $(head -2 "$GDIR/events.log" 2>/dev/null | tr '\n' ' ')"
if grep -q 'gh-gate:' "$TMP/gate-mut-err" 2>/dev/null; then
  fail "  …BUT a pacing note reached the SUCCESSFUL (retried) call's stderr: $(head -2 "$TMP/gate-mut-err" | tr '\n' ' ')"
else
  pass "  …and the successful retried call's stderr stayed byte-clean"
fi

echo "== 14. the gate must not corrupt its callers, and must not be corrupted by them (#1910 review) =="

# (a) ⛔ THE ONE THAT MATTERS MOST. A successful call's stderr must be BYTE-IDENTICAL to the
#     child's. The layer above (`gh-rest/gh`) does `run_real … 2>&1 | jq`, so a single pacing
#     note beside a good answer is a JSONDecodeError on `pr view --json` and a reported FAILURE
#     for a `pr merge` GitHub already performed. The pre-fix shim announced the wait on stderr.
GDIR="$(gate_dir quiet)"
GREAL="$TMP/gate-real-quiet"; GFLAG="$TMP/gate-quiet-flag"; rm -f "$GFLAG"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
if [ ! -f "$GFLAG" ]; then
  : > "$GFLAG"
  echo 'API rate limit already exceeded for user ID 1' >&2
  exit 1
fi
printf '{\"number\":1,\"title\":\"ok\"}\n'
GHEOF
chmod +x "$GREAL"
cout="$(AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
        AGENT_GH_GATE_RETRY_BASE=1 GFLAG="$GFLAG" \
        bash "$SHIM" api user 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$cout" | head -1 | grep -qE '^\{'; then
  pass "a SUCCEEDED (and retried) call leaves stderr byte-clean — the merged 2>&1 is still JSON"
else
  fail "a successful call contaminated stderr (the gh-rest JSONDecodeError class): $(printf '%s' "$cout" | head -1)"
fi
grep -q 'gh-gate: GitHub refused' "$GDIR/events.log" 2>/dev/null \
  && pass "  …and the pacing note was still recorded, in events.log" \
  || fail "  …but the note vanished entirely (an operator cannot see the gate working)"

# (b) …while a call that finally FAILS must still announce why, on stderr.
GDIR="$(gate_dir loud)"
GREAL="$TMP/gate-real-loud"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
echo 'API rate limit already exceeded for user ID 1' >&2
exit 1
GHEOF
chmod +x "$GREAL"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  AGENT_GH_GATE_RETRY_BASE=1 bash "$SHIM" api user >/dev/null 2>"$TMP/gate-loud-err"
grep -q 'gh-gate: GitHub refused' "$TMP/gate-loud-err" \
  && pass "a call that finally FAILS still announces the retry on stderr" \
  || fail "a failing call swallowed its own announcement"

# (c) SIGPIPE: `tr … | grep -Eq …` under `set -o pipefail` returns 141 once stderr exceeds the
#     pipe buffer, and 141 reads as "not rate limited". ⛔ THE MATCH MUST COME FIRST and the padding
#     AFTER: `grep -q` only exits early (and only then SIGPIPEs `tr`) while `tr` still has bytes to
#     write — a fixture that puts the match LAST never triggers it and passes on the pre-fix code.
GDIR="$(gate_dir big)"
GREAL="$TMP/gate-real-big"; GFLAG="$TMP/gate-big-flag"; rm -f "$GFLAG"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
if [ ! -f "$GFLAG" ]; then
  : > "$GFLAG"
  echo 'API rate limit already exceeded for user ID 1' >&2
  head -c 4194304 /dev/zero | tr '\0' 'x' >&2
  echo '' >&2
  exit 1
fi
printf '{\"ok\":true}\n'
GHEOF
chmod +x "$GREAL"
bout="$(AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
        AGENT_GH_GATE_RETRY_BASE=1 GFLAG="$GFLAG" \
        bash "$SHIM" api user 2>/dev/null)"
printf '%s' "$bout" | grep -q '"ok":true' \
  && pass "a 4 MB refusing stderr (match FIRST, so \`tr\` takes SIGPIPE) is still recognised" \
  || fail "a large refusing stderr was not recognised — the retry/cooldown is silently dead"

# (d) A `retry-after` `[ ]` cannot hold must be treated as ABSENT, never clamped-and-wrapped: the
#     wrap is written into the SHARED cooldown and parks every lane on the box for ~10^15 years.
#     ⛔ MAX_ATTEMPTS MUST BE 2, NOT 1: the loop breaks on `tries -ge MAX_ATTEMPTS-1` at tries=0 when
#     it is 1, so `set_cooldown_ms` is never reached and "no cooldown written" is true for a reason
#     that has nothing to do with the overflow guard. With 2 the arm exercises the real path and
#     discriminates (pre-fix wrote 1.86e18; post-fix a bounded 900 s).
GDIR="$(gate_dir ovf)"
GREAL="$TMP/gate-real-ovf"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
echo 'API rate limit exceeded' >&2
echo 'retry-after: 9999999999999999999' >&2
exit 1
GHEOF
chmod +x "$GREAL"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  AGENT_GH_GATE_MAX_ATTEMPTS=2 AGENT_GH_GATE_RETRY_BASE=1 \
  bash "$SHIM" api user >/dev/null 2>&1
ovf="$(cat "$GDIR"/cooldown.* 2>/dev/null | head -1)"
# The invariant is that the WRAPPED deadline never reaches the shared file: either it was never
# written (treated as absent) or it was bounded. A poisoned ~1.86e18 value fails both arms.
if [ -z "$ovf" ]; then
  pass "an unrepresentable retry-after is treated as absent — no poisoned deadline written"
else
  _now=$(( $(date +%s) * 1000 ))
  if [ "$ovf" -le $(( _now + 900000 )) ] 2>/dev/null; then
    pass "an unrepresentable retry-after is bounded to RETRY_MAX, not wrapped"
  else
    fail "retry-after overflow poisoned the shared cooldown with $ovf (a fleet-wide stall)"
  fi
fi

# (e) A caller that declared its own bound must not be slept inside this gate.
GDIR="$(gate_dir nowait)"
_s=$(date +%s)
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  AGENT_GH_GATE_RETRY_BASE=60 bash "$SHIM" api user >/dev/null 2>&1
_e=$(date +%s)
[ $(( _e - _s )) -le 5 ] \
  && pass "GH_LIMIT_NO_WAIT=1 returns the refusal at once (elapsed $(( _e - _s ))s, not 60s)" \
  || fail "NO_WAIT was ignored — the gate slept $(( _e - _s ))s inside a bounded caller"

# (f) The caller's cancellation must reach `gh`: a killed caller must not leave the child running
#     through its retries against a bucket GitHub has already refused.
GDIR="$(gate_dir sig)"; GREAL="$TMP/gate-real-sig"; SPID="$TMP/gate-sig-pid"; rm -f "$SPID"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
echo $$ > "$SPID"
sleep 30
GHEOF
chmod +x "$GREAL"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 SPID="$SPID" \
  bash "$SHIM" api user >/dev/null 2>&1 &
_shim=$!
_slept=0; while [ ! -s "$SPID" ] && [ "$_slept" -lt 20 ]; do sleep 0.1; _slept=$(( _slept + 1 )); done
_child="$(cat "$SPID" 2>/dev/null)"
kill -TERM "$_shim" 2>/dev/null
sleep 1
if [ -n "$_child" ] && ! kill -0 "$_child" 2>/dev/null; then
  pass "the caller's TERM reaches the gh child (no orphaned request)"
else
  kill -9 "$_child" 2>/dev/null
  fail "the gh child outlived its caller — an orphaned request against a refused bucket"
fi

# (g) An unusable gate/capture dir must not STOP the call: bash performs `2>"$errf"` BEFORE exec, so
#     a failed redirection means `gh` never runs and the caller gets rc=1 from a courtesy gate.
GDIR="$(mktemp -d "$TMP/gate-ro.XXXXXX")"
GREAL="$TMP/gate-real-ro"
printf '#!/usr/bin/env bash\nprintf %s\n' "'{\"ok\":true}'" > "$GREAL"
chmod +x "$GREAL"
chmod 500 "$GDIR"
roout="$(AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR/gate" TMPDIR="$GDIR" \
        bash "$SHIM" api user 2>&1)"; rorc=$?
chmod 700 "$GDIR"
if [ "$rorc" -eq 0 ] && printf '%s' "$roout" | grep -q '"ok":true'; then
  pass "an unwritable gate/capture dir still runs the call (rc=0)"
else
  fail "an unwritable capture dir stopped the call (rc=$rorc) — the gate failed CLOSED"
fi
printf '%s' "$roout" | grep -q 'Permission denied' \
  && fail "  …and a failed redirect leaked a shell error onto the caller's stderr" \
  || pass "  …and left the caller's stderr clean"
# ── 15. THE WRAPPER RULE: SKIP EVERY SHIM, NEVER ONLY $SELF (#1988 ↔ #1910) ──
# `scripts/orchestrator-harness/gh-rest/gh` and `gh-limit/gh` are harness gh layers of their
# own, and each resolves the next `gh` on PATH. MEASURED on #1988: two shims that each skip
# ONLY themselves resolve to EACH OTHER — 1,700 processes in 6 s, ending in
# `fork: Resource temporarily unavailable`. #1988 closed that by carrying a sentinel line
# (`harness-gh-shim-marker`) and refusing any candidate that carries it.
#
# This shim is the OUTERMOST layer in a harness session (the review-enforcer puts it first),
# so the rule it must obey is: skip ANY candidate that is a shim — its own path THROUGH
# SYMLINKS (`-ef`, §10(a)) and the sentinel-marked harness layers — never only `$SELF_DIR`.
# If that regressed, this shim would EXEC the harness layer, which resolves back here, and
# the fleet would fork-loop. A hang is not a status, so the arms are bounded in time.
echo "== 15. the resolver skips EVERY shim, never only \$SELF (#1988) =="

# A fake `gh-limit/gh` carrying #1988's sentinel. It records that it RAN, on disk, so the
# assertion is a fact about a file rather than about text that a later arm could emit.
harness_layer_at() {  # <dir> <did-run-file>
  mkdir -p "$1"
  cat > "$1/gh" <<GHEOF
#!/usr/bin/env bash
# harness-gh-shim-marker — #1988's identity line (see gh-limit.py); the argv shim must skip it.
printf 'HARNESS-LAYER-RAN\n'
: > "$2"
exit 0
GHEOF
  chmod +x "$1/gh"
}

# (a) a sentinel-marked harness layer sits BETWEEN this shim and the real gh.
# ⛔ FILE, NOT A CAPTURE PIPE (review of #2295). `out="$( … & … )"` cannot report the very failure
# it exists to detect: the recursion's descendants INHERIT the substitution's write end, so after
# `kill -9 $p` the substitution still waits for an EOF that never comes — the CASE HANGS instead of
# reporting, and the `*HUNG*` arm below is precisely the arm that cannot fire (reproduced: rc=124).
# Same file + reap shape as (a2)/(a3), which is why they carry this reasoning too.
HRAN="$TMP/harness-layer-ran-14a"
rm -f "$HRAN"
harness_layer_at "$TMP/gh-limit-14a" "$HRAN"
: > "$TMP/a1.out"
( cd "$TMP" && env -u AGENT_GH_REAL -u SCEN \
  PATH="$TMP/neutral:$TMP/gh-limit-14a:$TMP/bin:/usr/bin:/bin" \
  bash "$TMP/neutral/gh" pr view 1 ) >>"$TMP/a1.out" 2>&1 &
p=$!
bound_then_reap "$p" "$TMP/neutral/gh" "$TMP/a1.out"
out="$(cat "$TMP/a1.out")"
case "$out" in
  *HUNG*) fail "with a harness layer on PATH the shim HUNG — the two wrappers resolve into each other" ;;
  *HARNESS-LAYER-RAN*) fail "the shim EXEC'd the harness gh layer (#1988) — that layer resolves back here, so the pair fork-loops" ;;
  *REALGH-CALLED*) pass "a sentinel-marked harness layer on PATH is SKIPPED; the real gh runs" ;;
  *) fail "with a harness layer on PATH the real gh never ran: $out" ;;
esac
[ -e "$HRAN" ] \
  && fail "  …but the harness layer WAS executed (a side-effect file proves it ran, whatever the output looked like)" \
  || pass "  …and the harness layer was never executed (no side-effect file)"

# (b) THE RULE IS A SENTINEL, NOT A DIRECTORY NAME. A gh that merely looks like the harness
#     layer but carries no marker is an ORDINARY gh and must be used — otherwise the skip
#     over-blocks every wrapper on the box.
mkdir -p "$TMP/plaingh"
cat > "$TMP/plaingh/gh" <<'GHEOF'
#!/usr/bin/env bash
printf 'PLAIN-GH-RAN
'
exit 0
GHEOF
chmod +x "$TMP/plaingh/gh"
out="$( cd "$TMP" && env -u AGENT_GH_REAL -u SCEN PATH="$TMP/plaingh:/usr/bin:/bin" \
  bash "$SHIM" pr view 1 2>&1 )"
case "$out" in
  *PLAIN-GH-RAN*) pass "an UNMARKED gh earlier on PATH is used (the skip is a sentinel, not a name)" ;;
  *) fail "an unmarked gh earlier on PATH was not used: $out" ;;
esac

# (c) THE ENV SEAM REFUSES A HARNESS LAYER TOO (#1988, review of #2295). The seam's third refusal —
#     an inherited `AGENT_GH_REAL` naming `$O/gh-rest/gh` or `$O/gh-limit/gh` — was silently
#     missing: the value was accepted as "the real gh", re-entered the shim chain, and the
#     harness's own depth guard ended EVERY gh call in the tree with rc 127 (measured). (a)/(b)
#     above pin the PATH half only, and pinning one half is exactly how the halves drifted apart:
#     the `-f` half of this same seam had the same shape. The harness layer is placed BEFORE the
#     real-gh stub on PATH, so if the shim wrongly execs it the side-effect file proves it.
HL4="$TMP/gh-limit-14c"; HRAN4="$TMP/harness-layer-ran-14c"
rm -f "$HRAN4"
harness_layer_at "$HL4" "$HRAN4"
: > "$TMP/a4.out"
( cd "$TMP" && env AGENT_GH_REAL="$HL4/gh" SCEN= PATH="$TMP/neutral:$HL4:$TMP/bin:/usr/bin:/bin" \
    bash "$TMP/neutral/gh" pr view 1 ) >>"$TMP/a4.out" 2>&1 &
p=$!
bound_then_reap "$p" "$TMP/neutral/gh" "$TMP/a4.out"
out="$(cat "$TMP/a4.out")"
case "$out" in
  *HUNG*) fail "AGENT_GH_REAL=<a harness layer> HUNG — the env seam re-entered the shim chain" ;;
  *HARNESS-LAYER-RAN*) fail "AGENT_GH_REAL=<a harness layer> was EXEC'd (#1988) — the env seam does not skip what the PATH walk skips" ;;
  *REALGH-CALLED*) pass "AGENT_GH_REAL=<a harness layer> is refused and resolution FALLS THROUGH to the real gh" ;;
  *) fail "AGENT_GH_REAL=<a harness layer> did not reach the real gh: $out" ;;
esac
[ -e "$HRAN4" ] \
  && fail "  …but the harness layer WAS executed (a side-effect file proves it ran, whatever the output looked like)" \
  || pass "  …and the harness layer was never executed (no side-effect file)"

# (d) ⛔ THE MARKER'S ABSENCE IS LOAD-BEARING, SO PIN IT (review of #2295). `gh-rest/gh` resolves
#     `REAL_GH` through this same sentinel test and then execs it, so if THIS shim's first 8 KiB
#     ever carried the marker, gh-rest would skip the shim and mutations would reach the real gh
#     DIRECTLY — silently bypassing #984's argv-level admin-merge guard. It holds today only by
#     byte count (the marker sits outside the first 8 KiB — pinned by §15(d) rather than by an offset
#     written here, because this very commit moved one such number), so a future comment edit could move it into
#     the window with nothing failing. No pipe and no command substitution over a binary: this
#     file is a text script, so `head` here can never emit a null byte.
_h8="$(head -c 8192 "$SHIM")"
case "$_h8" in
  *harness-gh-shim-marker*)
    fail "THIS SHIM carries the harness marker in its first 8 KiB — gh-rest would SKIP it, so mutations would bypass the admin-merge guard (#984)" ;;
  *) pass "this shim does not carry the harness marker in its first 8 KiB, so gh-rest still delegates mutations through it" ;;
esac



echo "== 16. cycle-2/3 review: no deletion, no stall, no leak, a visible degraded gate (#1910 review) =="

# (a) ⛔ WORKDIR OWNERSHIP. `gate_init` falls back to the OPERATOR'S $TMPDIR when `mktemp -d`
#     fails, and run_paced's cleanup was `[ "$GATE_DIR" = "$WORKDIR" ] || rm -rf "$WORKDIR"` —
#     which deleted $TMPDIR WITH ITS CONTENTS on a call that then exited 0, printing nothing.
#     Reproduced before the fix: a directory holding PRECIOUS.txt vanished.
GDIR="$TMP/gate-unwritable"
GREAL="$TMP/gate-real-tmpdir"
printf '#!/usr/bin/env bash\necho \x27{"ok":true}\x27\n' > "$GREAL"; chmod +x "$GREAL"
mkdir -p "$TMP/p0stub" "$TMP/precious"
printf '#!/usr/bin/env bash\nexit 1\n' > "$TMP/p0stub/mktemp"; chmod +x "$TMP/p0stub/mktemp"
echo IMPORTANT > "$TMP/precious/PRECIOUS.txt"
PATH="$TMP/p0stub:$PATH" AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="/proc/nope/gate" \
  TMPDIR="$TMP/precious" bash "$SHIM" api user >/dev/null 2>&1
if [ -f "$TMP/precious/PRECIOUS.txt" ]; then
  pass "the fallback to \$TMPDIR is never deleted (the gate only removes a dir it created)"
else
  fail "the gate DELETED the operator's \$TMPDIR and its contents (silent destruction of work)"
fi

# (b) AN UNAVAILABLE MUTEX FAILS OPEN PROMPTLY. Re-looping to the admission deadline turned a
#     courtesy gate into a 299 s in-shim block (measured) that consumed a bounded caller's own
#     budget. ⛔ THE HOLDER MUST BE A LIVE PROCESS THIS USER OWNS: `kill -0 1` returns EPERM for a
#     non-root user, which the shim reads as "dead holder", reaps the lock and succeeds — so a
#     pid-1 fixture never enters the `return 2` path and passes on the pre-fix code too.
GDIR="$(gate_dir lockbusy)"
GREAL="$TMP/gate-real-lockbusy"
printf '#!/usr/bin/env bash\necho \x27{"ok":true}\x27\n' > "$GREAL"; chmod +x "$GREAL"
sleep 60 &
_LOCKHOLDER=$!
mkdir -p "$GDIR/admit.lock"; printf '%s\n' "$_LOCKHOLDER" > "$GDIR/admit.lock/pid"
_ls=$(date +%s)
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  bash "$SHIM" api user >/dev/null 2>&1
_le=$(date +%s)
kill "$_LOCKHOLDER" 2>/dev/null; wait "$_LOCKHOLDER" 2>/dev/null
[ $(( _le - _ls )) -le 15 ] \
  && pass "an uncontestable mutex fails OPEN in $(( _le - _ls ))s, not $(( ${AGENT_GH_GATE_ACQUIRE_TIMEOUT:-300} ))s" \
  || fail "an uncontestable mutex blocked the caller for $(( _le - _ls ))s — the gate's failure mode was a stall"

# (b2) A CALLER THAT DECLARED ITS OWN BOUND IS NOT SLEPT OUT OF A SHARED WINDOW EITHER. This was
#      the last path by which a NO_WAIT caller still reported STALL: the window is capped by
#      RETRY_MAX (900 s default), and `wait_for_cooldown` ran BEFORE the NO_WAIT check.
GDIR="$(gate_dir nowaitwin)"
_until=$(( $(date +%s) * 1000 + 15000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
_ns=$(date +%s)
GH_LIMIT_NO_WAIT=1 AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_INTERVAL_MS=0 \
  bash "$SHIM" api user >/dev/null 2>&1
_ne=$(date +%s)
[ $(( _ne - _ns )) -le 5 ] \
  && pass "a NO_WAIT caller is not slept out of a 15 s shared window (elapsed $(( _ne - _ns ))s)" \
  || fail "a NO_WAIT caller was slept out of a shared window ($(( _ne - _ns ))s) — STALL, not RATE-LIMITED"

# (b3) A NO_WAIT CALLER STILL HOLDS ITS SLOT. Suppressing the WAIT must not suppress the CAP:
#      releasing the slot before falling through let a burst of NO_WAIT callers run concurrently
#      exactly during a window (measured: 3 children at MAX_INFLIGHT=1).
GDIR="$(gate_dir nowaitslot)"
GACTIVE2="$TMP/gate-nowait-active"; rm -rf "$GACTIVE2"; mkdir -p "$GACTIVE2"
GREAL2="$TMP/gate-real-nowaitslot"; _obs="$TMP/gate-nowait-observed"; : > "$_obs"
cat > "$GREAL2" <<'GHEOF'
#!/usr/bin/env bash
# Each child records how many children are ACTIVE the instant it starts. Deterministic — a sampler
# that runs after `wait` reads 0 and would pass with the cap wide open (it did).
: > "$GACTIVE2/$$"
echo "$(ls "$GACTIVE2" | wc -l | tr -d ' ')" >> "$OBSERVED"
sleep 0.5
rm -f "$GACTIVE2/$$"
exit 0
GHEOF
chmod +x "$GREAL2"
_until=$(( $(date +%s) * 1000 + 3000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
for _l in 1 2 3; do
  AGENT_GH_GATE_MAX_INFLIGHT=1 AGENT_GH_GATE_NO_WAIT=1 AGENT_GH_GATE_INTERVAL_MS=0 \
    AGENT_GH_REAL="$GREAL2" AGENT_GH_GATE_DIR="$GDIR" GACTIVE2="$GACTIVE2" \
    OBSERVED="$_obs" bash "$SHIM" api user >/dev/null 2>&1 &
done
wait
_max=0
while read -r _n; do
  case "$_n" in ''|*[!0-9]*) continue ;; esac
  [ "$_n" -gt "$_max" ] && _max="$_n"
done < "$_obs"
[ "$_max" -le 1 ] && [ "$_max" -ge 1 ] \
  && pass "a NO_WAIT caller keeps its slot: max concurrency $_max at MAX_INFLIGHT=1 during a window" \
  || fail "NO_WAIT concurrency cap wrong (saw max $_max children at MAX_INFLIGHT=1; expected exactly 1)"

# (c) A DEGRADED GATE MUST STILL LEAVE A TRACE. The note says the call runs "UNGATED (announced)",
#     and the buffered copy is discarded on success — so nothing was recorded anywhere, and the
#     runbook's "read the log" had nothing to read.
_degraded="${HOME:-${TMPDIR:-/tmp}}/.pi/agent/gh-gate-degraded.log"
rm -f "$_degraded"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="/proc/nope/gate" bash "$SHIM" api user >/dev/null 2>&1
[ -s "$_degraded" ] \
  && pass "a degraded gate records the fail-open in a durable file outside the gate dir" \
  || fail "a degraded gate recorded nothing — 'announced' was untrue and the log had no entry"

# (d) ONE LANE'S KNOB MUST NOT DELETE THE BOX'S WINDOW. The cooldown self-heal compared a SHARED
#     deadline against the READING lane's per-invocation AGENT_GH_GATE_RETRY_MAX, so a lane running
#     with a smaller value deleted a window every other lane was waiting on. The call legitimately
#     WAITS OUT the window, so start it, give it 2 s, stop it, and ask whether the window survived.
GDIR="$(gate_dir sharedwin)"
_until=$(( $(date +%s) * 1000 + 800000 ))
printf '%s\n' "$_until" > "$GDIR/cooldown.$_until.$$"
AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" AGENT_GH_GATE_RETRY_MAX=60 \
  AGENT_GH_GATE_INTERVAL_MS=0 bash "$SHIM" api user >/dev/null 2>&1 &
_sw=$!
sleep 2
kill -TERM "$_sw" 2>/dev/null; wait "$_sw" 2>/dev/null
if ls "$GDIR"/cooldown.* >/dev/null 2>&1; then
  pass "a +800 s window survives a lane running with AGENT_GH_GATE_RETRY_MAX=60"
else
  fail "a per-call knob deleted a shared cooldown window other lanes were waiting on"
fi

# (e) AN INTERACTIVE CALL IS NOT EXEMPT FROM THE STDERR INVARIANT. The branch used to print the
#     pending notes BEFORE running the child, so a SUCCESSFUL call contaminated `2>&1` — and
#     `gh-rest/gh` reaches this shim as `run_real … 2>&1 | jq` with a human's tty on stdin, so this
#     is a real caller, not a hypothetical one. Asserted on the branch's SHAPE because the behaviour
#     needs a pty and `python3 pty.spawn` did not return on this box even after the child exited.
#     The shape is the whole regression: nothing may write before the child, and the notes must be
#     flushed AFTER it, from its exit status (the same rule every other branch follows).
_iblock="$(awk '/if \[ "\$interactive" -eq 1 \]; then/,/^    fi$/' "$SHIM")"
if [ -z "$_iblock" ]; then
  fail "could not locate the interactive branch in $SHIM (the shape assertion is stale)"
else
  _ibad=0
  case "$_iblock" in *'cat "$NOTEF"'*) _ibad=1 ;; esac
  case "$_iblock" in *'gate_note'*) _ibad=1 ;; esac
  case "$_iblock" in *'flush_notes "$rc"'*) : ;; *) _ibad=1 ;; esac
  [ "$_ibad" -eq 0 ] \
    && pass "the interactive branch writes nothing before the child and flushes notes from its rc" \
    || fail "the interactive branch can print before the child (contaminating a successful call)"
fi

# ── 17. THE HOP-DEPTH BOUND (#2304) ──────────────────────────────────────
# The `-ef` guards refuse THIS file, and `-ef` is device+inode — so a COPY of the shim at another
# inode is invisible to them, and two copies reachable from each other resolve to EACH OTHER, one
# `exec` per generation, each taking a gate slot. MEASURED in production (2026-10-22 → 11-06):
# 3,456 bash processes and load 74 on 4 vCPU, then `fork: Resource temporarily unavailable` so the
# box could not be cleaned up from inside; later 146 shims with both slots held by hops 1 AND 2, so
# every unrelated gh call paid the full 300 s acquire timeout and then ran UNGATED. The precondition
# needs no unusual caller: `~/.pi/agent/shims/gh` (a COPY) and `scripts/gh-shim/gh` (a COPY) BOTH on
# PATH, reachable from each other — `extensions/review-enforcer` falls back to `fs.copyFileSync` when
# symlinking its neutral entry fails, which is exactly how the second copy appears.
#
# ⛔ EVERY ARM HERE IS MUTATION-SENSITIVE, and the shape is the reason: with the generation counter
# removed (or its threshold raised), (a) never terminates and is graded HUNG by bound_then_reap,
# while (b)/(c) cannot observe any counter at all. Nothing else in this suite runs a ladder, so
# these are the only cases that can.
echo "== 17. a COPY of this shim on PATH is bounded (#2304) =="

# Two copies at two DIFFERENT inodes, both on PATH — the ping-pong precondition. `cp` (not `ln`)
# is the point: `-ef` sees a symlink, never a copy.
mkdir -p "$TMP/cpA" "$TMP/cpB"
cp "$SHIM" "$TMP/cpA/gh"; cp "$SHIM" "$TMP/cpB/gh"
chmod +x "$TMP/cpA/gh" "$TMP/cpB/gh"
_cpa_inode="$(ls -i "$TMP/cpA/gh" | awk '{print $1}')"
_cpb_inode="$(ls -i "$TMP/cpB/gh" | awk '{print $1}')"
[ "$_cpa_inode" != "$_cpb_inode" ] \
  && pass "the fixture is two COPIES (different inodes: $_cpa_inode / $_cpb_inode), which is what \`-ef\` cannot see" \
  || fail "the fixture is ONE inode — this section would not test the copy class at all"

# Real gh that records the GENERATION COUNTER it was handed. That counter is the process count of
# the ladder that produced the call: every hop increments it and exports it before the exec, so a
# value of 1 means exactly ONE shim process, 2 means a nested hop — no sampler, nothing to race.
DEPTHSTUB="$TMP/cp-realdepth"
cat > "$DEPTHSTUB" <<'GHEOF'
#!/usr/bin/env bash
printf 'REALGH-CALLED depth=%s argv=%s\n' "${AGENT_GH_SHIM_DEPTH:-unset}" "$*" >> "${DEPTHLOG:?}"
exit 0
GHEOF
chmod +x "$DEPTHSTUB"
DEPTHLOG="$TMP/cp-depth.log"; : > "$DEPTHLOG"

# (a) THE LADDER. copy A resolves copy B as "the real gh"; B is handed its OWN path in
#     AGENT_GH_REAL, refuses it (that is the #2266 half), and walks PATH to A — forever. All three
#     processes append to a file rather than a pipe, and the whole tree is reaped by path: on the
#     regression this arm exists to catch, a capture pipe would never see EOF and the arm could not
#     fire (the §10/§15 lesson).
: > "$TMP/a17a.out"; rm -f "$TMP/a17a.rc"
_a17s=$(date +%s)
( cd "$TMP" && env -u AGENT_GH_REAL -u AGENT_GH_SHIM_DEPTH -u SCEN -u AGENT_GH_GATE_SLOT \
    DEPTHLOG="$DEPTHLOG" PATH="$TMP/cpA:$TMP/cpB:$TMP/bin:/usr/bin:/bin" \
    bash "$TMP/cpA/gh" pr view 1 >"$TMP/a17a.out" 2>&1; printf '%s' "$?" >"$TMP/a17a.rc" ) &
_p=$!
bound_then_reap "$_p" "$TMP/cp" "$TMP/a17a.out"
_a17e=$(date +%s)
_a17out="$(cat "$TMP/a17a.out")"
_a17rc="$(cat "$TMP/a17a.rc" 2>/dev/null)"
case "$_a17out" in
  *HUNG*) fail "two COPIES of the shim on PATH did not terminate — unbounded recursion, the #2304 fork storm" ;;
  *'REFUSING a third gh-shim hop'*'AGENT_GH_SHIM_DEPTH=2'*)
          pass "two copies on PATH terminate at the THIRD hop with a named refusal (\`AGENT_GH_SHIM_DEPTH=2\`) — 3 processes, not 3.4k" ;;
  *)      fail "the copy ladder ended without the hop-depth refusal: $_a17out" ;;
esac
[ "$_a17rc" = "127" ] \
  && pass "  …and the refusal is a NON-ZERO status (rc=127), so no caller mistakes it for an answer" \
  || fail "  …but the ladder's status was '${_a17rc:-<none>}' (expected 127)"
case "$_a17out" in
  *'no gh slot free'*) fail "  …and it reached the SLOT STALL before the depth bound: the two halves must ship together (#2304)" ;;
  *) pass "  …and it never reached the slot stall (the depth bound ends it before a second slot is needed)" ;;
esac
[ "$(( _a17e - _a17s ))" -le 10 ] \
  && pass "  …within $(( _a17e - _a17s ))s (bounded, not a 300 s-per-hop stall)" \
  || fail "  …but the bounded ladder still took $(( _a17e - _a17s ))s"
[ -s "$DEPTHLOG" ] \
  && fail "  …but a real gh WAS reached during the ladder ($(head -1 "$DEPTHLOG")) — this fixture did not reproduce the copy class" \
  || pass "  …and no real gh was reached at all (each copy accepted the other as 'the real gh')"

# (b) ⛔ THE BOUND MUST NOT OVER-BLOCK A LEGITIMATE NESTED CALL. Two generations is the genuine
#     maximum: the call a session starts, plus the one its verifier (or real gh's own
#     `git` credential helper) makes. Refusing THAT would break the evidence read the admin-merge
#     gate depends on — an over-block is a real defect, not a safe default.
#     ⛔ THE EVIDENCE IS THE LOG, NOT STDOUT. The pacing notes are buffered and replayed only when a
#     call FAILS, and a real gh on a `pr view` prints nothing anyway; so "did the stub run?" must be
#     asked of the file the stub writes — asserting on stdout reads an EMPTY string and calls a
#     working hop a failure (measured on the first run of this arm).
: > "$DEPTHLOG"
_a17bout="$( cd "$TMP" && env AGENT_GH_SHIM_DEPTH=1 AGENT_GH_REAL="$DEPTHSTUB" DEPTHLOG="$DEPTHLOG" \
  PATH="$TMP/cpA:$TMP/bin:/usr/bin:/bin" bash "$SHIM" pr view 1 2>&1 )"; _a17brc=$?
case "$(cat "$DEPTHLOG" 2>/dev/null)" in
  *REALGH-CALLED*) pass "a NESTED call at generation 2 is still allowed (no over-block)" ;;
  *) fail "a NESTED call at generation 2 did not reach the real gh (log: '$(cat "$DEPTHLOG" 2>/dev/null)' out: '$_a17bout')" ;;
esac
case "$_a17bout" in
  *'REFUSING a third gh-shim hop'*) fail "  …and it was REFUSED — the bound over-blocks the verifier's own gh call" ;;
  *) pass "  …and it was not refused by the hop-depth bound" ;;
esac
[ "$_a17brc" -eq 0 ] && pass "  …and it succeeded (rc=0)" || fail "  …but it exited rc=$_a17brc"
grep -q 'depth=2' "$DEPTHLOG" 2>/dev/null \
  && pass "  …carrying AGENT_GH_SHIM_DEPTH=2 into the real gh (the counter is exported per hop)" \
  || fail "  …but the real gh saw $(sed -n 1p "$DEPTHLOG" 2>/dev/null) instead of depth=2"

# (c) ⛔ THE PROCESS COUNT FOR ONE ORDINARY CALL IS 1 — the issue's own acceptance indicator, and
#     the reason it is stated as a count: the failure mode was never a wrong ANSWER, it was a
#     process tree. An unresolvable request must exit non-zero promptly, having spawned exactly one
#     shim, with the request named by the real gh rather than by a downstream failure.
UNRES="$TMP/cp-realunres"
cat > "$UNRES" <<'GHEOF'
#!/usr/bin/env bash
printf 'REALGH-CALLED depth=%s argv=%s\n' "${AGENT_GH_SHIM_DEPTH:-unset}" "$*" >> "${DEPTHLOG:?}"
printf 'Could not resolve to a PullRequest with the number of 99999997.\n' >&2
exit 1
GHEOF
chmod +x "$UNRES"
: > "$DEPTHLOG"
_c17s=$(date +%s)
_a17cout="$( cd "$TMP" && env -u AGENT_GH_SHIM_DEPTH AGENT_GH_REAL="$UNRES" DEPTHLOG="$DEPTHLOG" \
  bash "$SHIM" pr view 99999997 2>&1 )"; _a17crc=$?
_c17e=$(date +%s)
[ "$_a17crc" -ne 0 ] \
  && pass "an UNRESOLVABLE request exits non-zero (rc=$_a17crc) instead of recursing" \
  || fail "an unresolvable request exited 0"
case "$_a17cout" in
  *'Could not resolve to a PullRequest with the number of 99999997'*) pass "  …and the error NAMES the request, not a downstream failure" ;;
  *) fail "  …but the error did not name the request: $_a17cout" ;;
esac
_c17n="$(grep -c 'REALGH-CALLED' "$DEPTHLOG" 2>/dev/null || echo 0)"
_c17d="$(sed -n '1s/.*depth=\([^ ]*\) .*/\1/p' "$DEPTHLOG" 2>/dev/null)"
if [ "$_c17n" = "1" ] && [ "$_c17d" = "1" ]; then
  pass "  …having spawned exactly ONE shim generation (1 real-gh call, depth=1) — the process count is 1"
else
  fail "  …but the call produced $_c17n real-gh call(s) at depth '${_c17d:-?}' — the process count is not 1"
fi
[ "$(( _c17e - _c17s ))" -le 5 ] \
  && pass "  …within $(( _c17e - _c17s ))s" \
  || fail "  …but it took $(( _c17e - _c17s ))s"

# (d)/(e) THE NESTED-SLOT HALF, PINNED IN BOTH DIRECTIONS. `admit_slot` creates the slot as a regular
#     FILE while the nested test was `-d`, so NO nested call was ever recognised and every one took a
#     SECOND slot — the cap doubled in the fail-OPEN direction. Measured with a valid inherited slot
#     at MAX_INFLIGHT=1 ACQUIRE_TIMEOUT=2: 2067 ms then `no gh slot free within 2s — running this
#     call UNGATED`; with `-f`: 34 ms, no note. ⛔ And this MUST ship with the depth bound: slot
#     reuse removes the natural brake on a two-copy ladder (the same pair measured 3 hops then a
#     300 s stall with `-d`, and 9 processes in 2 s with `-f`), so `-f` alone is what turns a slow
#     ladder into the #2266 fork loop that (a) is now bounded against.
GDIR="$(gate_dir nested)"
GREAL_N="$TMP/cp-realnested"
printf '#!/usr/bin/env bash\nprintf \x27NESTED-REAL-RAN\\n\x27\nexit 0\n' > "$GREAL_N"; chmod +x "$GREAL_N"
mkdir -p "$GDIR/slots"
sleep 60 & _holder=$!
printf '%s\n' "$_holder" > "$GDIR/slots/held.$$"
_NS="$TMP/cp-nested-slot"; : > "$_NS"
_d_s=$(date +%s)
_d_out="$( cd "$TMP" && env AGENT_GH_REAL="$GREAL_N" AGENT_GH_GATE_DIR="$GDIR" \
  AGENT_GH_GATE_MAX_INFLIGHT=1 AGENT_GH_GATE_ACQUIRE_TIMEOUT=1 AGENT_GH_GATE_INTERVAL_MS=0 \
  AGENT_GH_GATE_SLOT="$_NS" bash "$SHIM" api user 2>&1 )"; _d_rc=$?
_d_e=$(date +%s)
# ⛔ ASK THE GATE'S OWN LOG, NOT STDERR. Pacing notes are buffered and replayed only when the call
# FAILS (`gh-rest/gh` parses a successful call's merged bytes as JSON), so on a SUCCESSFUL call the
# note exists only in `$GATE_DIR/events.log` — grepping stderr reads nothing and grades a stall as a
# pass (measured on the first run of this arm).
case "$(cat "$GDIR/events.log" 2>/dev/null)" in
  *'no gh slot free'*) fail "an inherited slot as a REGULAR FILE was not recognised as nested (waited out the cap) — the \`-d\` test on a file, the #2304 fail-open" ;;
  *)                   : ;;
esac
case "$_d_out" in
  *NESTED-REAL-RAN*) pass "an inherited slot FILE is recognised as nested: no second slot, no wait ($(( _d_e - _d_s ))s)" ;;
  *)                 fail "the nested call did not reach the real gh: $_d_out" ;;
esac
[ "$_d_rc" -eq 0 ] && pass "  …and it succeeded (rc=0)" || fail "  …but it exited rc=$_d_rc"
# (e) THE POLARITY: a DIRECTORY is not a slot, so a forged value cannot skip the CAP (only pacing).
#     ⛔ ITS OWN GATE DIR, because the two arms of this pair ASSERT THE OPPOSITE THING about the same
#     string, and (d)'s stall note would still be in a shared `events.log` — (e) would then read (d)'s
#     evidence and pass whatever it did (measured: on the `-d` mutant (e) went green off (d)'s note).
GDIR2="$(gate_dir nested2)"; mkdir -p "$GDIR2/slots"
sleep 60 & _holder2=$!
printf '%s\n' "$_holder2" > "$GDIR2/slots/held.$$"
_d2_s=$(date +%s)
_e_out="$( cd "$TMP" && env AGENT_GH_REAL="$GREAL_N" AGENT_GH_GATE_DIR="$GDIR2" \
  AGENT_GH_GATE_MAX_INFLIGHT=1 AGENT_GH_GATE_ACQUIRE_TIMEOUT=1 AGENT_GH_GATE_INTERVAL_MS=0 \
  AGENT_GH_GATE_SLOT="$GDIR2" bash "$SHIM" api user 2>&1 )"; _e_rc=$?
_d2_e=$(date +%s)
kill "$_holder" "$_holder2" 2>/dev/null; wait "$_holder" "$_holder2" 2>/dev/null
rm -f "$GDIR/slots/held.$$" "$GDIR2/slots/held.$$"
case "$(cat "$GDIR2/events.log" 2>/dev/null)" in
  *'no gh slot free'*) pass "a DIRECTORY value is NOT a slot: the call honours the cap and reports the wait (fail-closed)" ;;
  *) fail "a DIRECTORY-valued AGENT_GH_GATE_SLOT bypassed the slot cap: '$_e_out'" ;;
esac
[ $(( _d2_e - _d2_s )) -ge 1 ] \
  && pass "  …and it really waited out the occupied cap ($(( _d2_e - _d2_s ))s at ACQUIRE_TIMEOUT=1)" \
  || fail "  …but it returned in $(( _d2_e - _d2_s ))s, so it never paid the admission wait"
[ "$_e_rc" -eq 0 ] \
  && pass "  …and it still runs (the gate fails OPEN after the wait, never onto the caller's timeout)" \
  || fail "  …but the ungated fallback did not run the call (rc=$_e_rc)"

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures of $checks gh-shim test(s) failed"
  exit 1
fi
echo "✅ all $checks gh-shim tests passed"
