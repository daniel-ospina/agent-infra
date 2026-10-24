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
#   13(f) the gate never asks `rate_limit` how healthy the account is,
#   13(g) a non-rate-limit 403 is NOT retried (a mutating command must not run twice).
echo "== 13. the fleet courtesy gate: bounded concurrency, spacing, 403/429 handling (#1910) =="

# A hermetic gate state per arm: never the operator's ~/.pi/agent/gh-gate.
gate_dir() { local d="$TMP/gate-$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }

# (a) BOUNDED CONCURRENCY. The fake gh holds a marker file for 0.4 s so overlap is
#     measurable; a sampler records the highest count seen. 4 lanes, cap 2 → 2, never 4.
GDIR="$(gate_dir conc)"; GACTIVE="$TMP/gate-conc-active"; rm -rf "$GACTIVE"; mkdir -p "$GACTIVE"
GREAL="$TMP/gate-real-conc"
cat > "$GREAL" <<'GHEOF'
#!/usr/bin/env bash
: > "$GACTIVE/$$"
sleep 0.4
rm -f "$GACTIVE/$$"
exit 0
GHEOF
chmod +x "$GREAL"
(
  maxc=0; i=0
  while [ "$i" -lt 60 ]; do
    n=$(ls "$GACTIVE" 2>/dev/null | wc -l)
    [ "$n" -gt "$maxc" ] && maxc="$n"
    printf '%s' "$maxc" > "$TMP/gate-conc-max"
    sleep 0.05; i=$(( i + 1 ))
  done
) &
sampler=$!
gpids=""
for _lane in 1 2 3 4; do
  GACTIVE="$GACTIVE" AGENT_GH_REAL="$GREAL" AGENT_GH_GATE_DIR="$GDIR" \
    AGENT_GH_GATE_MAX_INFLIGHT=2 AGENT_GH_GATE_INTERVAL_MS=0 \
    bash "$SHIM" api user >/dev/null 2>&1 &
  gpids="$gpids $!"
done
for p in $gpids; do wait "$p"; done
kill "$sampler" 2>/dev/null; wait "$sampler" 2>/dev/null
maxc="$(cat "$TMP/gate-conc-max" 2>/dev/null || echo 0)"
[ "${maxc:-0}" -le 2 ] && [ "${maxc:-0}" -ge 1 ] \
  && pass "4 parallel lanes with MAX_INFLIGHT=2 → at most 2 gh processes in flight (saw $maxc)" \
  || fail "the concurrency bound did not hold: saw $maxc in flight with a cap of 2"
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

# (f) THE GATE's HEALTH SIGNAL IS ITS OWN IN-FLIGHT COUNT. `GET /rate_limit` reports only
#     the primary budget, so asking it would be exactly the #1762 mistake. Pin that no
#     executed line of the shim references the ENDPOINT (header prose may; the code may
#     not). The pattern excludes the gate's own `rate_limited` helper, which is this file's
#     own function name and says nothing about the API.
rl_refs=$(grep -v '^[[:space:]]*#' "$SHIM" | grep -cE 'rate_limit([^a-z_]|$)' || true)
[ "${rl_refs:-1}" -eq 0 ] \
  && pass "no executed line consults \`rate_limit\` — the gate's own slot count is the signal" \
  || fail "the shim's CODE now reads rate_limit ($rl_refs reference(s)) — it cannot see the secondary limit"

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

if [ "$failures" -gt 0 ]; then
  echo "❌ $failures of $checks gh-shim test(s) failed"
  exit 1
fi
echo "✅ all $checks gh-shim tests passed"
