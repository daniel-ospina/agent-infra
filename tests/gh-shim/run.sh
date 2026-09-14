#!/usr/bin/env bash
# tests/gh-shim/run.sh — the ARGV-LEVEL admin-merge guard (#984).
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

export SCEN=""
new_scen() {
  SCEN="$TMP/scen-$1"
  rm -rf "$SCEN"; mkdir -p "$SCEN"
  : > "$SCEN/calls"
  printf '{"headRefOid":"%s","comments":[]}' "$HEAD_A" > "$SCEN/pr.json"
}

# A body that satisfies the certifying contract, bound to <head>.
cert_body() {
  printf '<!-- admin-merge-safety: %s -->\nPR head: %s\ntest lane: python-ci.yml\nmain compared (union of 7 runs of python-ci.yml): a:1\nPR failing: 15 | main failing: 19 | unique to this PR: 0\n' "$1" "$1"
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
  {body:"main compared (union of 7 runs of x): a:1\nPR failing: 1 | main failing: 0 | unique to this PR: 0"}]}' > "$SCEN/pr.json"
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
printf '<!-- admin-merge-safety: %s -->\nPR head: %s\nmain compared (union of 1 run of x): a:1\nPR failing: 0 | main failing: 0 | unique to this PR: 0.5\n' "$HEAD_A" "$HEAD_A" > "$TMP/body-half"
bash "$VERIFY" --body-file "$TMP/body-half" --head "$HEAD_A" >/dev/null 2>&1 \
  && fail "\`unique to this PR: 0.5\` certified — a non-zero residual passed" \
  || pass "\`unique to this PR: 0.5\` does NOT certify (the zero clause is exact)"

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
  printf '<!-- admin-merge-safety: %s -->\nPR head: %s\nmain compared (union of 1 run of x): a:1\nPR failing: 0 | main failing: 0 | unique to this PR: %s\n' "$HEAD_A" "$HEAD_A" "$evil" > "$TMP/body-evil"
  bash "$VERIFY" --body-file "$TMP/body-evil" --head "$HEAD_A" >/dev/null 2>&1 \
    && fail "\`unique to this PR: $evil\` certified" \
    || pass "\`unique to this PR: $evil\` does NOT certify"
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
out="$( cd "$TMP" && env -u AGENT_GH_REAL -u SCEN PATH="$TMP/neutral:$TMP/bin:/usr/bin:/bin" \
  bash "$TMP/neutral/gh" pr view 1 2>&1 & 
  p=$!
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12; do kill -0 "$p" 2>/dev/null || break; sleep 0.5; done
  if kill -0 "$p" 2>/dev/null; then kill -9 "$p" 2>/dev/null; printf 'HUNG'; fi )"
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

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures of $checks gh-shim test(s) failed"
  exit 1
fi
echo "✅ all $checks gh-shim tests passed"
