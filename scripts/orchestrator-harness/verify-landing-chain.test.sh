#!/usr/bin/env bash
# verify-landing-chain.test.sh — offline suite for verify-landing-chain.sh.
#
# HERMETIC: every case is a SNAPSHOT DIRECTORY (`--from-snapshot`), so there is no network, no gh, no
# clock. The point of each case is a DECISION that has already been wrong once, in the direction that
# costs the most:
#
#   * a FALSE FAIL on a correct landing (case 3). The first cut compared `tree(reviewed)` to
#     `tree(merge)` and failed PR #3996 — main had moved between the branch point and the squash, so
#     the trees legitimately differ. A verifier that fails correct landings gets ignored, which is
#     the same outcome as not having one.
#   * a FALSE PASS on a re-run that laundered a red (cases 6, 7). A re-run ADDS a check-run; it does
#     not clear the old one. Counting "the newest attempt overall" instead of "the newest attempt
#     that had completed by mergedAt" reports a red landing green.
#   * a FALSE PASS on a same-named job in a different workflow (case 8). Two workflows can publish
#     `packaging-smoke`; grouping by the name alone lets the newer of one mask the older of the other.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/verify-landing-chain.sh"
pass=0; fail=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail + 1)); }
ck()  { if [ "$2" -eq 0 ]; then ok "$1"; else bad "$1"; fi; }

T="$(mktemp -d)"; MUT="$T/mut"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home"   # the pinned, key-less HOME `run_verify` reads
[ -s "$SCRIPT" ] || { bad "verify-landing-chain.sh is missing or empty"; exit 1; }

# ── fixture helpers ───────────────────────────────────────────────────────────────────────────────
# One snapshot = one PR. Defaults describe a CLEAN landing; a case overrides only what it is about, so
# a case's name is the whole difference it asserts.
REPO_FIXTURE="o/r"
MERGED_AT="2026-11-12T05:05:55Z"
HEAD="1111111111111111111111111111111111111111"
MERGE="2222222222222222222222222222222222222222"
HEAD_TREE="d950506a5b5500000000000000000000000000aa"
LAND_TREE="a2d8a39b183a00000000000000000000000000bb"

mk() { # mk <case-name> <pr>  → prints the snapshot root
  local root="$T/$1" pr="$2"
  mkdir -p "$root/pr-$pr"
  printf '%s\n' "$REPO_FIXTURE" > "$root/repo.txt"
  printf '%s\t%s\t%s\t%s\n' "$pr" MERGED "$MERGED_AT" "$MERGE" > "$root/pr-$pr/pr.meta"
  printf '%s\n' "$HEAD" > "$root/pr-$pr/pr-commits.tsv"
  printf '%s\t%s\t\n' "$MERGE" "$LAND_TREE" > "$root/pr-$pr/commit-$MERGE.tsv"
  printf '%s\t%s\t\n' "$HEAD" "$HEAD_TREE" > "$root/pr-$pr/commit-$HEAD.tsv"
  printf 'review recorded: reviews/%s.json verdict=clean @ %s (o/r)\n' "$pr" "$HEAD" > "$root/pr-$pr/body.txt"
  : > "$root/pr-$pr/comments.txt"
  printf '%s\n' "$root"
}

# comment <root> <pr> <author_association> <body…> — append ONE comment in the PRODUCER's frame
# (`<author_association>\x1f<body>\x1e`, `check-pipeline-compliance.sh`'s REVIEW_COMMENTS_JQ). A fixture
# must speak the producer's grammar: the old `<<<COMMENT>>>` line frame carried no author at all, which
# is why nothing downstream could apply the gate's admission rule for a whole review cycle.
# ⛔ …INCLUDING the newline `jq -r` writes after every record. The reader must strip it, or a trusted
# author reads as "\nOWNER" and is refused for a reason the report cannot show — so every comment fixture
# below carries that byte, and the suite would catch the strip being dropped.
comment() {
  local root="$1" pr="$2" assoc="$3" body="$4"
  printf '%s\037%s\036\n' "$assoc" "$body" >> "$root/pr-$pr/comments.txt"
}
TEST_KEY="a-test-gate-key"
sign_marker() { # sign_marker <marker text> [key] → prints "… sig=<hex>", exactly as the recorder does
  printf '%s sig=%s' "$1" \
    "$(printf '%s' "$1" | openssl dgst -sha256 -hmac "${2:-$TEST_KEY}" 2>/dev/null | awk '{print $NF}')"
}
record_sig() { # record_sig <pr> <head> <verdict> <repo> [key] → the gate's canonical record HMAC
  printf 'review-record:v1:%s:%s:%s:%s' "$1" "$2" "$3" "$4" \
    | openssl dgst -sha256 -hmac "${5:-$TEST_KEY}" 2>/dev/null | awk '{print $NF}'
}

# group <root> <pr> <check-run id> <workflow-run-id> <job name> <status> <conclusion> <completed_at>
# run   <root> <pr> <workflow-run-id> <workflow name> <run attempt>
# group <root> <pr> <id> <run> <name> <status> <conclusion> <completed_at> [started_at]
# `started_at` is the 8th field of the surface the script reads, and it is OPTIONAL in the API (null for
# a run that is still queued) — so it is optional here too. It was missing from this helper, which made
# every "started before the merge, voted after" case unreachable in the suite: F1t silently degraded
# into "the re-run is a post-merge job" and asserted the wrong sentence.
group() {
  local d="$1/pr-$2" line
  line="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "$3" "github-actions" "$5" "$6" "$7" "$8" \
    "https://github.com/o/r/actions/runs/$4/job/1")"
  if [ -n "${9:-}" ]; then line="$line$(printf '\t%s' "$9")"; fi
  printf '%s\n' "$line" >> "$d/checkruns-$HEAD.tsv"
}
run() { # run <root> <pr> <run-id> <workflow name> <run attempt> [workflow path]
  if [ -n "${6:-}" ]; then
    printf '%s\t%s\t%s\t%s\n' "$3" "$4" "$5" "$6" >> "$1/pr-$2/runs-$HEAD.tsv"
  else
    printf '%s\t%s\t%s\n' "$3" "$4" "$5" >> "$1/pr-$2/runs-$HEAD.tsv"
  fi
}
# rail_land <root> <pr> [extra line…] — the rail's OWN landing line, verbatim from the producer:
#   admin-merge.sh:12402  info "admin-merge: ✅ merged PR #$PR at $landed_sha (state=… confirmed via the API)"
# A fixture must speak the PRODUCER's grammar. The first version of this suite wrote
# `admin-merge: ok` — a line the rail never prints — and a presence-only reader PASSed on it, which is
# exactly how the round-6 false PASS shipped and stayed invisible for five rounds.
rail_land() {
  local root="$1" pr="$2" l; shift 2
  printf 'admin-merge: ✅ merged PR #%s at %s (state=MERGED confirmed via the API; branch head was %s…)\n' \
    "$pr" "$MERGE" "${HEAD:0:12}" > "$root/pr-$pr/rail.out"
  for l in "$@"; do printf '%s\n' "$l" >> "$root/pr-$pr/rail.out"; done
}
# Both surfaces are captured for every case: the TEXT report is what a human reads (so its DETAIL is
# asserted where the detail is the finding), and the JSON is what a report file consumes (so its SHAPE
# is asserted where the verdict is the finding). Asserting one and reading the other is how a suite
# passes over a report nobody can parse.
# ⛔ HERMETIC AT THE GATE KEY TOO (fresh-context review, round 8). Since the review-record admission was
# added, the reader verifies a marker`s `sig=` against AI_REVIEW_GATE_KEY (env first, else
# `$HOME/.pi/agent/.ai-review-gate-key`) — and every box that MINTS review records has that key file.
# Unpinned, the same fixture would be admitted on a dev box and refused on a CI runner, which is the
# opposite of hermetic. So `HOME` is a fresh empty directory, and VKEY is the ONLY way a case supplies a
# key: empty means "no key on this box" (the association is then the admission, as on a runner), a value
# means "a key resolves here, so a sig must verify".
VKEY=""
run_verify() { HOME="$T/home" AI_REVIEW_GATE_KEY="$VKEY" bash "$SCRIPT" "$@"; }
verify() { # verify <root> [extra args]  → sets OUT (text), OUTJ (json), returns the script's exit code
  local root="$1"; shift
  OUT="$(run_verify --from-snapshot "$root" --repo "$REPO_FIXTURE" "$@" 2>&1)"
  rc=$?
  OUTJ="$(run_verify --from-snapshot "$root" --repo "$REPO_FIXTURE" --json "$@" 2>&1)"
  return $rc
}
# ⛔ NO `printf | grep -q` (round 4, F1 — BLOCKING). That shape is the SIGPIPE false-negative idiom
# `scripts/check-no-sigpipe-grep.sh` exists to refuse (#841/#864): under `pipefail` a quiet grep exits
# BEFORE the writer finishes, the writer dies of SIGPIPE, and the pipeline reports 141 — so the
# assertion inverts. The repo's own suite records `sigpipe-grep` as a REQUIRED PR check, so this file
# would have redded CI. A here-string drops the pipe entirely and keeps every grep flag.
has()  { grep -qF -- "$1" <<<"$OUT"; }
hasj() { grep -qF -- "$1" <<<"$OUTJ"; }

# ── case 1: the clean landing — every check PASS, exit 0 ─────────────────────────────────────────
R="$(mk clean 401)"
run "$R" 401 9001 "CI" 1; group "$R" 401 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 401
verify "$R" --json; rc=$?
ck "clean landing exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
ck "clean landing: review_bound PASS (reviewed head IS the final commit)" "$(hasj '"check":"review_bound","verdict":"PASS"'; echo $?)"
ck "clean landing: green_gated PASS" "$(hasj '"check":"green_gated","verdict":"PASS"'; echo $?)"
ck "clean landing: rail_landed PASS" "$(hasj '"check":"rail_landed","verdict":"PASS"'; echo $?)"
ck "clean landing: --json is parseable JSON" "$(printf '%s' "$OUTJ" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; echo $?)"

# ── case 2: code pushed AFTER the review — the attestation stands over content nobody reviewed ────
R="$(mk pushed-after-review 402)"
printf '%s\n%s\n' "$HEAD" "3333333333333333333333333333333333333333" > "$R/pr-402/pr-commits.tsv"
run "$R" 402 9001 "CI" 1; group "$R" 402 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"; rc=$?
ck "pushed-after-review exits 1" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"
ck "pushed-after-review: review_bound FAIL" "$(has "commits pushed AFTER the review and never re-reviewed: 333333333333"; echo $?)"

# ── case 3: ⛔ THE MEASURED FALSE FAIL — main moved, so trees differ, but the head IS the tip ─────
# Reproduces PR #3996: head tree != merge tree, reviewed head == the PR's last commit. MUST PASS.
R="$(mk squash-main-moved 403)"
run "$R" 403 9001 "CI" 1; group "$R" 403 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 403
verify "$R"; rc=$?
ck "squash-main-moved: review_bound PASS despite differing trees (#3996 regression)" "$(hasj '"check":"review_bound","verdict":"PASS"'; echo $?)"
ck "squash-main-moved exits 0" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ── case 4: a not-clean verdict superseded at a new head — the fix round DID happen ───────────────
R="$(mk fix-round 404)"
{
  printf 'review recorded: reviews/404.json verdict=not-clean @ %s (o/r) findings=1\n' "$HEAD"
  printf 'review recorded: reviews/404.json verdict=clean @ %s (o/r)\n' "4444444444444444444444444444444444444444"
} > "$R/pr-404/body.txt"
printf '%s\n%s\n' "$HEAD" "4444444444444444444444444444444444444444" > "$R/pr-404/pr-commits.tsv"
run "$R" 404 9001 "CI" 1; group "$R" 404 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"
ck "fix-round: fix_round PASS (not-clean superseded at a new head)" "$(has "was superseded by clean@444444444444"; echo $?)"

# ── case 5: a not-clean that was never superseded — condition 4 unmet ────────────────────────────
R="$(mk no-fix-round 405)"
printf 'review recorded: reviews/405.json verdict=not-clean @ %s (o/r) findings=2\n' "$HEAD" > "$R/pr-405/body.txt"
run "$R" 405 9001 "CI" 1; group "$R" 405 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"; rc=$?
ck "no-fix-round: fix_round FAIL (the only marker IS the refusal)" "$(has "is the NEWEST record for this PR"; echo $?)"
ck "no-fix-round: …and it is not reported as a round that converged" "$(has "did not converge"; echo $?)"
ck "no-fix-round exits 1" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# ── case 6: ⛔ THE RE-RUN LAUNDER — red completed BEFORE the merge, green AFTER. Must stay RED. ──
R="$(mk rerun-launder 406)"
run "$R" 406 9001 "CI" 1
group "$R" 406 10 9001 "pipeline-compliance" completed failure   "2026-11-12T04:41:17Z"
group "$R" 406 20 9001 "pipeline-compliance" completed success   "2026-11-12T05:24:50Z"   # after 05:05:55
verify "$R"; rc=$?
ck "rerun-launder: green_gated FAIL (a green that finished after the merge gated nothing)" "$(has "green exists but completed AFTER mergedAt"; echo $?)"
ck "rerun-launder exits 1" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# ── case 7: the same shape, but the green DID complete before the merge → PASS ───────────────────
R="$(mk rerun-before-merge 407)"
run "$R" 407 9001 "CI" 1
group "$R" 407 10 9001 "pipeline-compliance" completed failure "2026-11-12T04:41:17Z"
group "$R" 407 20 9001 "pipeline-compliance" completed success "2026-11-12T05:01:00Z"
verify "$R"
ck "rerun-before-merge: green_gated PASS (the re-run is what the landing saw)" "$(hasj '"check":"green_gated","verdict":"PASS"'; echo $?)"

# ── case 8: ⛔ SAME JOB NAME, TWO WORKFLOWS — the name-only grouping masks a red ─────────────────
# Workflow A publishes `packaging-smoke` success (newer id 30); workflow B publishes the same name
# failure (older id 20). Grouped by (app, workflow, name) these are TWO groups and B is RED. Grouped
# by the NAME alone the newer id 30 wins and the red disappears — the exact masking measured on real
# check-runs. The verdict must be FAIL.
R="$(mk same-name-two-workflows 408)"
run "$R" 408 9001 "Workflow A" 1; run "$R" 408 9002 "Workflow B" 1
group "$R" 408 20 9002 "packaging-smoke" completed failure "2026-11-12T04:00:00Z"
group "$R" 408 30 9001 "packaging-smoke" completed success "2026-11-12T04:10:00Z"
verify "$R"; rc=$?
ck "same-name-two-workflows: green_gated FAIL (name-only grouping would have masked the red)" "$(has "Workflow B/packaging-smoke:failure"; echo $?)"

# ── case 8b: ⛔ SAME JOB NAME, TWO WORKFLOWS THAT SHARE A DISPLAY *NAME* ────────────────────────
# Fresh-context review, round 7, P3: the workflow component was the display `name`, which a repo can
# repeat, so two DISTINCT workflows still collapsed into one group and the newer of one masked the
# other — case 8 was narrowed, not closed. The identity is the workflow's `path`, which is unique per
# repo and arrives in the same payload.
R="$(mk same-name-two-paths 472)"
run "$R" 472 9001 "CI" 1 ".github/workflows/ci.yml"
run "$R" 472 9002 "CI" 1 ".github/workflows/ci-mirror.yml"
group "$R" 472 20 9002 "packaging-smoke" completed failure "2026-11-12T04:00:00Z"
group "$R" 472 30 9001 "packaging-smoke" completed success "2026-11-12T04:10:00Z"
verify "$R"
ck "same-name-two-paths: two workflows sharing a DISPLAY name are still two groups" \
  "$(has ".github/workflows/ci-mirror.yml/packaging-smoke:failure"; echo $?)"
ck "same-name-two-paths: …so the red is not masked by the newer green" "$(has "VERDICT: NOT-ALL-MET"; echo $?)"

# ── case 8c: ⛔ THE `--json` EVIDENCE PATH MUST SURVIVE A BACKSLASH AND A QUOTE ────────────────
# Fresh-context review, round 7, P3: the escaper was `gsub(/\\/,"\\\\",o)`, and escape processing inside a
# gsub REPLACEMENT is not portable — measured on one input backslash it yields TWO on gawk/mawk/nawk
# defaults but ONE under `awk --posix`, i.e. a no-op that emits `\z`, which is not a JSON escape. A
# detail carrying a quote/backslash is reachable from a malformed `mergedAt` in `pr.meta`, so this is a
# real value path, not a hypothetical one.
R="$(mk json-escaping 473)"
printf '%s\t%s\t%s\t%s\n' 473 OPEN 'x"y\z' "$MERGE" > "$R/pr-473/pr.meta"
verify "$R" --json
ck "json-escaping: a backslash+quote in a detail is JSON-escaped, not emitted raw" \
  "$(hasj 'mergedAt=x\"y\\z'; echo $?)"
ck "json-escaping: …so the evidence file still parses" \
  "$(printf '%s' "$OUTJ" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; echo $?)"
ck "json-escaping: …and the detail round-trips to the bytes the report printed" \
  "$(printf '%s' "$OUTJ" | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(0 if any(c["detail"].find("mergedAt=x\"y\\z")>=0 for p in d["prs"] for c in p["checks"]) else 1)' >/dev/null 2>&1; echo $?)"
# the same report rendered by a POSIX-mode awk, when this box has one: this is the read that the
# escaped-replacement form could NOT survive, so it pins the portable-subset contract directly.
if awk --posix 'BEGIN{}' >/dev/null 2>&1; then
  OUTP="$(VERIFY_AWK='awk --posix' run_verify --from-snapshot "$R" --repo "$REPO_FIXTURE" --json 2>&1)"
  ck "json-escaping: the --json emitter is valid JSON under a POSIX-mode awk too" \
    "$(printf '%s' "$OUTP" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; echo $?)"
  ck "json-escaping: …and it carries the same escaped backslash there" \
    "$(grep -qF -- 'mergedAt=x\"y\\z' <<<"$OUTP"; echo $?)"
else
  ok "json-escaping: SKIPPED the POSIX-mode awk parity read — this box's awk has no --posix"
fi

# ── case 9: an UNRESOLVABLE workflow is grouped under its app, never dropped ─────────────────────
R="$(mk no-workflow 409)"
printf '30\tgithub-actions\topaque-check\tcompleted\tfailure\t2026-11-12T04:00:00Z\t-\n' > "$R/pr-409/checkruns-$HEAD.tsv"
verify "$R"
ck "no-workflow: an app-only check still forms a group and can go red" "$(has "app:github-actions/opaque-check:failure"; echo $?)"

# ── case 10: a novel conclusion is RED (allow-list polarity), and `cancelled` is not ─────────────
R="$(mk novel-conclusion 410)"
run "$R" 410 9001 "CI" 1
group "$R" 410 10 9001 "unit-test" completed success "2026-11-12T04:00:00Z"
group "$R" 410 20 9001 "startup" completed startup_failure "2026-11-12T04:01:00Z"
verify "$R"
ck "novel-conclusion: an undocumented conclusion is RED, never a pass" "$(has "CI/startup:startup_failure"; echo $?)"
R="$(mk cancelled-not-red 411)"
run "$R" 411 9001 "CI" 1
group "$R" 411 10 9001 "unit-test" completed success "2026-11-12T04:00:00Z"
group "$R" 411 20 9001 "flaky" completed cancelled "2026-11-12T04:01:00Z"
verify "$R"
ck "cancelled-not-red: a cancelled attempt is non-red" "$(hasj '"check":"green_gated","verdict":"PASS"'; echo $?)"

# ── case 11: an UNREAD surface is INCONCLUSIVE, never green ──────────────────────────────────────
R="$(mk surface-unreadable 412)"
printf '%s\n' "$HEAD" > "$R/pr-412/pr-commits.tsv"
verify "$R"; rc=$?
ck "surface-unreadable: green_gated INCONCLUSIVE" "$(hasj '"check":"green_gated","verdict":"INCONCLUSIVE"'; echo $?)"
ck "surface-unreadable exits 2 (an unread check is never a pass)" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

# ── case 12: an empty surface attached NOTHING — a FAIL, not a pass ──────────────────────────────
R="$(mk surface-empty 413)"
run "$R" 413 9001 "CI" 1
: > "$R/pr-413/checkruns-$HEAD.tsv"
verify "$R"
ck "surface-empty: green_gated FAIL (nothing attached is a measured zero, not an unknown)" "$(has "NOTHING had attached a verdict"; echo $?)"

# ── case 13: the landing route — a LANDING is proved, a refusal is not, and the chain is a FAIL ──
# ⛔ THIS CASE WAS REBUILT IN ROUND 6, AND THE OLD SHAPE WAS THE DEFECT. It used to write
# `admin-merge: merged via AGENT_ADMIN_MERGE_OVERRIDE=1` into `rail.out` and expect a FAIL, and to
# treat ANY non-empty `rail.out` as the rail having landed. Both readings are text scans of a scratch
# file the rail writes on every ATTEMPT (`auto-rail.sh:1705`, `:617`; its own `cooldown_for` parses
# refusals out of it), so a refusal read as an override landing and an ALREADY-MERGED no-op read as a
# landing at all — while MASKING the chain FAIL below it.
R="$(mk route-override 414)"
run "$R" 414 9001 "CI" 1; group "$R" 414 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 414 'audit: admin_merge_override (AGENT_ADMIN_MERGE_OVERRIDE=1)'
verify "$R"
ck "route-override: a LANDING that records the override is rail_landed FAIL" "$(has "together with an admin-merge override spelling"; echo $?)"
# the same text with NO landing line in the file is a REFUSAL that merely NAMES the route
# (admin-merge.sh:11093/11622 print `AGENT_ADMIN_MERGE_OVERRIDE=1. No evidence was posted and no merge
# attempted.`). It must never be reported as a bypass — that is a false accusation on the one
# predicate that decides condition 6.
R="$(mk route-override-named-not-taken 423)"
run "$R" 423 9001 "CI" 1; group "$R" 423 10 9001 "unit-test" completed success "$MERGED_AT"
printf 'admin-merge: ⛔ BLOCK — a red is visible on this tree. Landing a red tree on purpose is\n   AGENT_ADMIN_MERGE_OVERRIDE=1. No evidence was posted and no merge attempted.\n' > "$R/pr-423/rail.out"
verify "$R"; rc=$?
# ⛔ THE NEEDLE WAS DEAD (fresh-context review, round 9 — P3, MEASURED). It was
# "an admin-merge override is recorded", a sentence this script CANNOT print: the FAIL this case guards
# against says "… together with an admin-merge override spelling in the same attempt …" (round 7
# re-worded it from "same artifact" and the needle was never updated) and the PASS says "… and no
# override is recorded on it …", which contains neither phrase. `has` is a fixed-string grep, so the
# assertion evaluated to `echo 0` on EVERY run of this branch — a green line that asserts nothing, on the
# predicate that decides capstone condition 6, inside the case written for the round-7 false-accusation
# fix (that case would have printed the FAIL sentence and still passed). The bypass sentence below is
# the one the round-6 AND round-7 wordings both carry, so a regression that accuses this refusal of
# bypassing the rail now trips it.
ck "route-override-named-not-taken: a refusal that NAMES the override is not an override landing" \
  "$(has "together with an admin-merge override spelling" && echo 1 || echo 0)"
ck "route-override-named-not-taken: …and it is an INCONCLUSIVE route, never a PASS" \
  "$(hasj '"check":"rail_landed","verdict":"INCONCLUSIVE"' && has "records NO landing of #423" && echo 0 || echo 1)"
ck "route-override-named-not-taken: …so the run does not close the capstone (exit 2, not 0)" \
  "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"
R="$(mk route-chain 415)"
run "$R" 415 9001 "CI" 1; group "$R" 415 10 9001 "unit-test" completed success "$MERGED_AT"
: > "$R/pr-415/chain.merged"
verify "$R"
ck "route-chain: rail_landed FAIL (the chain landed it, not auto-rail)" "$(has "landed by the per-PR chain, not by auto-rail"; echo $?)"
R="$(mk route-absent 416)"
run "$R" 416 9001 "CI" 1; group "$R" 416 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"
ck "route-absent: rail_landed INCONCLUSIVE (no artifact ⇒ unknown, never a pass)" "$(hasj '"check":"rail_landed","verdict":"INCONCLUSIVE"'; echo $?)"
# ⛔ THE MASKING CASE THE OLD PREDICATE COULD NOT SEE: an earlier rail REFUSAL leaves a non-empty
# `rail.out`, and a chain landing happened afterwards. File presence used to PASS this and swallow the
# chain FAIL — a false PASS on condition 6, from an instrument whose exit 0 closes the capstone.
R="$(mk route-refused-then-chain 422)"
run "$R" 422 9001 "CI" 1; group "$R" 422 10 9001 "unit-test" completed success "$MERGED_AT"
printf 'admin-merge: ✅ PR #422 is ALREADY MERGED (state=MERGED, mergedAt=%s) — duplicate execution is a NO-OP: no CI work, no evidence comment, no merge attempt\n' "$MERGED_AT" > "$R/pr-422/rail.out"
: > "$R/pr-422/chain.merged"
verify "$R"; rc=$?
ck "route-refused-then-chain: an ALREADY-MERGED no-op is not a landing, so the chain FAIL is NOT masked" \
  "$(has "landed by the per-PR chain, not by auto-rail"; echo $?)"
ck "route-refused-then-chain: …and the run exits 1, never 0" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"
# …and the same no-op with NO chain marker is UNKNOWN, not a PASS and not a FAIL
R="$(mk route-noop-only 424)"
run "$R" 424 9001 "CI" 1; group "$R" 424 10 9001 "unit-test" completed success "$MERGED_AT"
printf 'admin-merge: ✅ PR #424 is ALREADY MERGED (state=MERGED, mergedAt=%s) — duplicate execution is a NO-OP: no CI work, no evidence comment, no merge attempt\n' "$MERGED_AT" > "$R/pr-424/rail.out"
verify "$R"
ck "route-noop-only: a no-op attempt leaves the route UNKNOWN" "$(has "records NO landing of #424"; echo $?)"
# ⛔ THE ROUND-6 FALSE PASS RE-OPENED THROUGH CONTENT (fresh-context review, round 7 — BLOCKING).
# `merge.log` IS the per-PR chain's own log — `merge-one.sh:122` sets `L="$O/logs/merge-$PR"` and
# `merge-one.sh:1119-1123` runs the rail with its stdout+stderr redirected into it — so a CHAIN landing
# writes the rail's `admin-merge: ✅ merged PR #N at <sha>` line into the very artifact this predicate
# used to accept as proof that auto-rail landed the PR on its own. Every chain landing then took the
# PASS arm and the chain FAIL below it was UNREACHABLE, in the exact shape it exists for. No fixture
# had ever written `merge.log`, which is why it survived round 6.
R="$(mk route-chain-mergelog-alone 468)"
run "$R" 468 9001 "CI" 1; group "$R" 468 10 9001 "unit-test" completed success "$MERGED_AT"
printf 'admin-merge: ✅ merged PR #468 at %s (state=MERGED confirmed via the API; branch head was %s…)\n' \
  "$MERGE" "${HEAD:0:12}" > "$R/pr-468/merge.log"
verify "$R"; rc=$?
ck "route-chain-mergelog-alone: the chain's own log is not an auto-rail landing" \
  "$(has "landed by the per-PR chain, not by auto-rail"; echo $?)"
ck "route-chain-mergelog-alone: …the detail names the artifact the landing line came from" \
  "$(has "is in merge.log"; echo $?)"
ck "route-chain-mergelog-alone: …rail_landed is never PASS here" "$(has "PASS  rail_landed" && echo 1 || echo 0)"
ck "route-chain-mergelog-alone: …so the run exits 1, never 0" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"
# …and the REAL chain shape: the marker AND the log the chain's own rail run wrote.
R="$(mk route-chain-mergelog 469)"
run "$R" 469 9001 "CI" 1; group "$R" 469 10 9001 "unit-test" completed success "$MERGED_AT"
: > "$R/pr-469/chain.merged"
printf 'admin-merge: ✅ merged PR #469 at %s (state=MERGED confirmed via the API; branch head was %s…)\n[merge 469] MERGED via the rail (attempt 1)\n' \
  "$MERGE" "${HEAD:0:12}" > "$R/pr-469/merge.log"
verify "$R"; rc=$?
ck "route-chain-mergelog: a chain landing is a rail_landed FAIL even with its log present" \
  "$(has "landed by the per-PR chain, not by auto-rail"; echo $?)"
ck "route-chain-mergelog: …never the PASS that closes the capstone" "$(has "PASS  rail_landed" && echo 1 || echo 0)"
ck "route-chain-mergelog: …exit 1" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"
# ⛔ AN EARLIER ATTEMPT'S WORDS ARE NOT THIS LANDING'S (fresh-context review, round 7, finding 3).
# The chain log is append-only across attempts and across heads (`merge-one.sh:1101-1105` records
# exactly that rule four lines above the redirect), and a REFUSAL names the override route
# (`admin-merge.sh:11622`: "AGENT_ADMIN_MERGE_OVERRIDE=1. No evidence was posted and no merge
# attempted."). So a PR refused once, fixed, and then landed normally was reported as a certificate
# BYPASS — a false accusation and a false FAIL on a correct landing (the #3996 class this predicate was
# rewritten to stop producing).
R="$(mk route-refusal-then-clean-landing 470)"
run "$R" 470 9001 "CI" 1; group "$R" 470 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 470
printf 'admin-merge: ⛔ BLOCK — a red is visible on this tree.\n   AGENT_ADMIN_MERGE_OVERRIDE=1. No evidence was posted and no merge attempted.\n' \
  > "$R/pr-470/merge.log"
verify "$R"
ck "route-refusal-then-clean-landing: a PRIOR refusal's override text does not fail this landing" \
  "$(hasj '"check":"rail_landed","verdict":"PASS"'; echo $?)"
ck "route-refusal-then-clean-landing: …and it is never reported as a bypass" \
  "$(has "together with an admin-merge override spelling" && echo 1 || echo 0)"

# ── case 14: an unmerged PR has no landing to verify ──────────────────────────────────────────────
R="$(mk unmerged 417)"
printf '%s\t%s\t%s\t%s\n' 417 OPEN - - > "$R/pr-417/pr.meta"
verify "$R"
ck "unmerged: merged FAIL" "$(hasj '"check":"merged","verdict":"FAIL"'; echo $?)"

# ── case 15: the record-file FALLBACK (a body with no marker) is a weaker but valid source ───────
# ⛔ THE RECORD FILE IS EVIDENCE ONLY WHEN ITS OWN `sig=` VERIFIES (fresh-context review, round 8 — the
# same admission, second channel). It leaves no trace on the PR — nobody can audit it — so an
# unauthenticated file at the store path was the worst half of the false-PASS class: it satisfied
# `review_record` AND `review_bound` from a `printf`. The gate refuses it (#1224 finding 3), so this
# reads it the same way: signed under the box's key ⇒ PASS naming `sig verified`; unsigned, or signed
# with no key on the box, ⇒ refused and REPORTED, never promoted.
R="$(mk record-file-fallback 418)"
: > "$R/pr-418/body.txt"
printf '{"pr":418,"head_sha":"%s","sig":"%s","verdict":"clean","repo":"o/r"}\n' \
  "$HEAD" "$(record_sig 418 "$HEAD" clean o/r)" > "$R/pr-418/record.json"
run "$R" 418 9001 "CI" 1; group "$R" 418 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 418
VKEY="$TEST_KEY"; verify "$R"; rc=$?; VKEY=""
ck "record-file-fallback: a SIGNED record file is admitted, naming the verification" \
  "$(has "source=record-file(sig verified)"; echo $?)"
ck "record-file-fallback: …and no row FAILs (a signed record is not a refusal)" \
  "$(has "VERDICT: NOT-ALL-MET" && echo 1 || echo 0)"
ck "record-file-fallback: …and the run is INCOMPLETE, because a record FILE carries no marker HISTORY for fix_round to read" \
  "$(has "VERDICT: INCOMPLETE" && echo 0 || echo 1)"
# …and the SAME file with no sig= is refused (no key resolves here, so nothing could verify it anyway)
R="$(mk record-file-unsigned 474)"
: > "$R/pr-474/body.txt"
printf '{"pr":474,"head_sha":"%s","verdict":"clean","repo":"o/r"}\n' "$HEAD" > "$R/pr-474/record.json"
run "$R" 474 9001 "CI" 1; group "$R" 474 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"; rc=$?
ck "record-file-unsigned: an UNSIGNED record file is refused, not adopted" \
  "$(has "carries NO sig= field"; echo $?)"
ck "record-file-unsigned: …and the run exits 2, never 0" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"
# …and a sig that does not verify under the present key is refused too (a different key / edited file)
R="$(mk record-file-badsig 475)"
: > "$R/pr-475/body.txt"
printf '{"pr":475,"head_sha":"%s","sig":"%s","verdict":"clean","repo":"o/r"}\n' \
  "$HEAD" "$(record_sig 475 "$HEAD" clean o/r "another-key")" > "$R/pr-475/record.json"
run "$R" 475 9001 "CI" 1; group "$R" 475 10 9001 "unit-test" completed success "$MERGED_AT"
VKEY="$TEST_KEY"; verify "$R"; rc=$?; VKEY=""
ck "record-file-badsig: a sig that does not verify is refused" \
  "$(has "sig= does not verify under this box gate key"; echo $?)"
ck "record-file-badsig: …and the run exits 2, never 0" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

# ── case 16: NO record at all is INCONCLUSIVE — an absent attestation is not a clean one ─────────
R="$(mk no-record 419)"
: > "$R/pr-419/body.txt"
run "$R" 419 9001 "CI" 1; group "$R" 419 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"; rc=$?
ck "no-record: review_record INCONCLUSIVE" "$(hasj '"check":"review_record","verdict":"INCONCLUSIVE"'; echo $?)"
ck "no-record exits 2 (never a pass by silence)" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

# ── case 17: an unmerged PR under --from-snapshot with no PR argument is VERIFIED, not skipped ────
# A snapshot root with two PRs must report both; a reader that silently verified only the first would
# make a two-PR record look like complete evidence.
ROOT="$T/multi"
mkdir -p "$ROOT"
printf '%s\n' "$REPO_FIXTURE" > "$ROOT/repo.txt"
for p in 420 421; do
  cp -R "$T/clean/pr-401" "$ROOT/pr-$p"
  sed -i.bak -e "s/^401/$p/" "$ROOT/pr-$p/pr.meta" 2>/dev/null || true
  rm -f "$ROOT/pr-$p"/*.bak
done
OUT="$(run_verify --from-snapshot "$ROOT" --repo "$REPO_FIXTURE" 2>&1)"
n="$(printf '%s\n' "$OUT" | grep -c '^PR #')"
ck "snapshot-auto: every PR in the snapshot is verified (saw $n of 2)" "$([ "$n" -eq 2 ] && echo 0 || echo 1)"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# THE FOUR FINDINGS FROM THE FRESH-CONTEXT REVIEW AT 4d23b74b2 — one case each, because each was a
# defect this file shipped and each was reachable in ONE of the two directions that matter.
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# F1 — a group that had STARTED but not voted when the merge happened is not a green.
# Before the fix, one green + two such groups printed "3 group(s) green" and PASSed.
R="$(mk f1-waited 440)"
run "$R" 440 9001 "CI" 1
group "$R" 440 10 9001 "unit-test"           completed success "2026-11-12T04:00:00Z"
group "$R" 440 20 9001 "vendor-drift"        in_progress -     "-"
group "$R" 440 30 9001 "pipeline-compliance" in_progress -     "-"
# started_at is field 8; rewrite the two in-flight rows so they began BEFORE the merge
awk -F'\t' 'BEGIN{OFS="\t"} $3=="vendor-drift" || $3=="pipeline-compliance" { $8="2026-11-12T04:30:00Z" } { print }' \
  "$R/pr-440/checkruns-$HEAD.tsv" > "$R/pr-440/c2" && mv "$R/pr-440/c2" "$R/pr-440/checkruns-$HEAD.tsv"
verify "$R"; rc=$?
ck "F1: an in-flight-at-merge group is not a green (no '3 group(s) green')" "$(has "did not wait for"; echo $?)"
if has "3 group(s) GREEN"; then
  bad "F1: the report still claims 3 green when only 1 group voted"
else
  ok "F1: no 3-green claim — the count is of groups that actually voted green"
fi

# F1b — a group with NO run at all by mergedAt (a post-merge job) is excluded, not counted
R="$(mk f1-later 441)"
run "$R" 441 9001 "CI" 1
group "$R" 441 10 9001 "unit-test" completed success "2026-11-12T04:00:00Z"
group "$R" 441 20 9001 "post-merge" completed success "2026-11-12T06:00:00Z"   # started after mergedAt
awk -F'\t' 'BEGIN{OFS="\t"} $3=="post-merge" { $8="2026-11-12T05:40:00Z" } { print }' \
  "$R/pr-441/checkruns-$HEAD.tsv" > "$R/pr-441/c2" && mv "$R/pr-441/c2" "$R/pr-441/checkruns-$HEAD.tsv"
rail_land "$R" 441
verify "$R"
ck "F1b: a post-merge-only group is excluded and the GREEN count is the measured 1" "$(has "1 group(s) GREEN"; echo $?)"

# F2a — an UNREAD surface is INCONCLUSIVE, never a measured zero (the fail-closed direction)
R="$(mk f2-unread 442)"
run "$R" 442 9001 "CI" 1
# the ORIGINAL bug left the truncated 0-byte artifact behind; both are present here on purpose, so a
# regression that stops honouring the sentinel lands on "measured zero" (FAIL) and this case flips.
: > "$R/pr-442/checkruns-$HEAD.tsv"
: > "$R/pr-442/checkruns-$HEAD.tsv.unread"
verify "$R"; rc=$?
ck "F2a: a rate-limited check-runs read is INCONCLUSIVE, not FAIL" "$(has "was NOT READ" ; echo $?)"
ck "F2a: …and the run exits 2 (unknown), not 1" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

# F2b — an UNREAD runs list is INCONCLUSIVE too: without run ids the app-only fallback merges two
# workflows that publish the same job name, so a failed read could mask a red in the GREEN direction.
R="$(mk f2-unread-runs 443)"
printf '9001\tWorkflow A\t1\n' > "$R/pr-443/runs-$HEAD.tsv"
: > "$R/pr-443/runs-$HEAD.tsv.unread"
run "$R" 443 9001 "CI" 1
group "$R" 443 10 9001 "unit-test" completed success "2026-11-12T04:00:00Z"
verify "$R"
ck "F2b: an unread workflow list is INCONCLUSIVE (grouping would be unsound)" "$(has "was NOT READ"; echo $?)"

# F3 — a marker naming ANOTHER repo is not evidence for this head
R="$(mk f3-foreign-marker 444)"
: > "$R/pr-444/body.txt"
comment "$R" 444 OWNER "$(printf 'review recorded: reviews/444.json verdict=clean @ %s (someone-else/other-repo)\n' "$HEAD")"
run "$R" 444 9001 "CI" 1; group "$R" 444 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"
ck "F3: a foreign-repo marker is REFUSED, not adopted (review_record INCONCLUSIVE)" "$(hasj '"check":"review_record","verdict":"INCONCLUSIVE"'; echo $?)"
ck "F3: …and the refusal is named" "$(has "refused as naming another repo"; echo $?)"

# F2c — a group still `queued` at the merge has a NULL `started_at`, so neither "started" nor "voted"
# is readable from timestamps; round 2's F2 found it falling into the PASS-eligible bucket while the
# report claimed "no run existed by mergedAt". It exists and did not vote, so it is `waited` → FAIL.
R="$(mk f2-queued-at-merge 447)"
run "$R" 447 9001 "CI" 1
group "$R" 447 10 9001 "unit-test"    completed success "2026-11-12T05:00:00Z"
group "$R" 447 20 9001 "vendor-drift" queued    -       "-"
verify "$R"; rc=$?
ck "F2c: a QUEUED group at mergedAt FAILs as 'did not wait for it'" "$(has "did not wait for"; echo $?)"
ck "F2c: …and it is never described as a group that did not exist yet" "$(has "no run existed by mergedAt" && echo 1 || echo 0)"
ck "F2c: …so the verdict is NOT-MET (exit 1), not a pass" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# F1t — round 5's F1 (BLOCKING, a false PASS): a re-run that STARTED before the merge and finished
# GREEN after it must not count as a green. Only a verdict KNOWN BY THE MERGE counts; this attempt
# existed and had not voted, so the group is `waited` → FAIL. The old rule classified it by its final
# conclusion and flipped the whole VERDICT to ALL-MET on nothing but the re-run's `started_at`.
R="$(mk f1t-started-before-voted-after 460)"
run "$R" 460 9001 "CI" 1
group "$R" 460 10 9001 "pipeline-compliance" completed success "2026-11-12T04:41:17Z" "2026-11-12T04:40:00Z"
group "$R" 460 20 9001 "pipeline-compliance" completed success "2026-11-12T05:24:50Z" "2026-11-12T05:00:00Z"
verify "$R"; rc=$?
ck "F1t: a re-run that had not voted by the merge FAILs as 'did not wait for'" "$(has "did not wait for"; echo $?)"
ck "F1t: …and the group is never reported GREEN" "$(has "1 group(s) GREEN" && echo 1 || echo 0)"
ck "F1t: …so the verdict is not ALL-MET (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# F3n — round 4's F3: an OLDER green must not outvote a NEWER attempt that never voted. The newest
# attempt at the merge was in flight, so the landing went ahead without a verdict from the job whose
# last word was green — the header's invariant ("the newest attempt of EVERY group was GREEN and
# completed") is false here, and the report used to assert it.
R="$(mk f3n-older-green-newer-inflight 455)"
run "$R" 455 9001 "CI" 1
group "$R" 455 10 9001 "unit-test" completed   success "2026-11-12T04:00:00Z" "2026-11-12T03:59:00Z"
group "$R" 455 20 9001 "unit-test" in_progress -       "-"                "2026-11-12T05:00:00Z"
verify "$R"; rc=$?
ck "F3n: a newer in-flight attempt hides the older green" "$(has "did not wait for"; echo $?)"
# ⛔ THE DEAD HALF IS GONE (round 6 note). The old line read
#   "$(has "unit-test.*GREEN"; has "1 group(s) GREEN" && echo 1 || echo 0)"
# and its FIRST call could never match anything: `has` is `grep -F` (fixed string), so the `.*` is
# literal. It contributed nothing to the verdict while looking like an assertion — the cheap way to
# look thorough, and exactly the class this suite exists to refuse.
ck "F3n: …and the group is never reported GREEN" "$(has "1 group(s) GREEN" && echo 1 || echo 0)"
ck "F3n: …so the run exits 1 (a FAIL), not 0" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# F2n — round 4's F2 (a FALSE PASS): a standing `not-clean` is not a review record. The marker was
# admitted and PASSed on the strength of being a marker, so a landing a reviewer REFUSED read as
# ALL-MET with exit 0 — from the instrument whose exit 0 says the capstone may close.
R="$(mk f2n-standing-not-clean 456)"
run "$R" 456 9001 "CI" 1
group "$R" 456 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 456
printf '<<<BODY>>>\nreview recorded: reviews/456.json verdict=not-clean @ %s (o/r)\n' "$HEAD" > "$R/pr-456/body.txt"
verify "$R"; rc=$?
ck "F2n: a standing not-clean FAILs review_record" "$(has "FAIL  review_record"; echo $?)"
ck "F2n: …and the run never exits 0" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"
ck "F2n: …and the reason names the refusal" "$(has "a reviewer REFUSED this revision"; echo $?)"

# F2o — round 4's F2, the fix_round half: not-clean → not-clean is not a converging round.
R="$(mk f2o-not-clean-twice 457)"
run "$R" 457 9001 "CI" 1
printf '<<<BODY>>>\nreview recorded: reviews/457.json verdict=not-clean @ %s (o/r)\nreview recorded: reviews/457.json verdict=not-clean @ %s (o/r)\n' "$MERGE" "$HEAD" > "$R/pr-457/body.txt"
verify "$R"
ck "F2o: not-clean → not-clean is a fix_round FAIL" "$(has "FAIL  fix_round"; echo $?)"
ck "F2o: …and the reason says the round did not converge" "$(has "the round did not converge"; echo $?)"

# F1r — round 3's F1: a green that completed BEFORE the merge, followed by a NEWER red attempt on the
# same job, must not be described as a green that arrived "AFTER mergedAt". The verdict (FAIL) is the
# same either way; the REASON is the part that was assumed instead of measured, and it was assumed in
# the flattering direction — a red landing explained away as a timing artifact.
R="$(mk f1r-green-then-red 450)"
run "$R" 450 9001 "CI" 1
group "$R" 450 10 9001 "unit-test" completed success "2026-11-12T04:00:00Z"
group "$R" 450 20 9001 "unit-test" completed failure "2026-11-12T04:30:00Z"
verify "$R"
ck "F1r: a green BEFORE the merge is named as such, not as a late green" \
  "$(has "a green DID complete before mergedAt but a NEWER attempt on the same job was RED"; echo $?)"
# ⛔ NO `|| true` ON A CHECK (round 6 note): the old line ended with it, so this assertion could never
# FAIL — a green line that asserted nothing, on the one sentence the case is about.
ck "F1r: …and this shape is NOT described as 'completed AFTER mergedAt'" \
  "$(has "completed AFTER mergedAt" && echo 1 || echo 0)"

# F1s — the mirror: a green that really did complete after the merge keeps ITS sentence (case 6 guards
# the verdict; this guards that the two shapes are not collapsed into one wording).
R="$(mk f1s-late-green 451)"
run "$R" 451 9001 "CI" 1
group "$R" 451 10 9001 "unit-test" completed failure "2026-11-12T04:41:17Z"
group "$R" 451 20 9001 "unit-test" completed success "2026-11-12T05:24:50Z"
verify "$R"
ck "F1s: a genuinely late green is named 'completed AFTER mergedAt'" \
  "$(has "a green exists but completed AFTER mergedAt"; echo $?)"
ck "F1s: …and is NOT described as having completed before the merge" \
  "$(has "a green DID complete before mergedAt" && echo 1 || echo 0)"

# F3c — the `.unread` sentinel on the RECORD channels must be READ (round 2's F3: it was written for
# body.txt/comments.txt and never consulted, so a failed body read was a measured absence and promoted
# an older comment marker to "this PR's current record"). Both forms are exercised: body only, and
# body+comments.
R="$(mk f3c-unread-body 448)"
run "$R" 448 9001 "CI" 1
group "$R" 448 10 9001 "unit-test" completed success "$MERGED_AT"
: > "$R/pr-448/body.txt"
: > "$R/pr-448/body.txt.unread"
comment "$R" 448 OWNER "$(printf 'review recorded: reviews/448.json verdict=clean @ %s (o/r)\n' "$HEAD")"
verify "$R"; rc=$?
ck "F3c: an unread body makes review_record INCONCLUSIVE" "$(has "the record channel(s) body.txt were NOT READ"; echo $?)"
ck "F3c: …and it does NOT promote the comment marker to PASS" "$(has "PASS  review_record" && echo 1 || echo 0)"
ck "F3c: …and the run exits 2 (unknown), never 0" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

R="$(mk f3c-unread-both 449)"
run "$R" 449 9001 "CI" 1
: > "$R/pr-449/body.txt";    : > "$R/pr-449/body.txt.unread"
: > "$R/pr-449/comments.txt"; : > "$R/pr-449/comments.txt.unread"
verify "$R"
ck "F3c: both channels unread names both of them" "$(has "body.txt,comments.txt"; echo $?)"

# F3c-route — round 3, note 2: the unread early return used to drop `rail_landed`, which artifacts can
# answer even when GitHub cannot. A 5-row report was the shape, and the row was the one this box knows.
R="$(mk f3c-unread-route 454)"
run "$R" 454 9001 "CI" 1; group "$R" 454 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 454
: > "$R/pr-454/body.txt"; : > "$R/pr-454/body.txt.unread"
verify "$R"; rc=$?
ck "F3c-route: the unread path still reports rail_landed" "$(has "PASS  rail_landed"; echo $?)"
ck "F3c-route: …and still exits 2, because the record is unknown" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

# F3b — a comment-only marker IS admitted, but declared as the weaker source the recorder refuses
R="$(mk f3-comment-marker 445)"
: > "$R/pr-445/body.txt"
comment "$R" 445 OWNER "$(printf 'review recorded: reviews/445.json verdict=clean @ %s (o/r)\n' "$HEAD")"
run "$R" 445 9001 "CI" 1; group "$R" 445 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 445
verify "$R"
ck "F3b: a comment-only marker is admitted as source=marker-comment (declared weaker)" "$(has "source=marker-comment"; echo $?)"

# F4 — a PR-number-keyed chain marker outside this PR's merge window is not proof (chain-merge.sh:246)
R="$(mk f4-out-of-window 446)"
run "$R" 446 9001 "CI" 1; group "$R" 446 10 9001 "unit-test" completed success "$MERGED_AT"
: > "$R/pr-446/chain.merged.out-of-window"
verify "$R"
ck "F4: an out-of-window chain marker leaves the route UNKNOWN, not chain-attributed" "$(has "OUTSIDE this PR's merge window"; echo $?)"
# F4b — round 6's P3: an UNPARSEABLE `mergedAt` used to SKIP the window test entirely and admit the
# number-keyed marker — an unusable window read as an open one, the fail-open direction F4 exists to
# close. The fixture carries the sentinel `fetch_one` now writes in that state (a snapshot cannot
# fetch, exactly as the F4 case above does); the sentinel's WRITER is pinned by the `chain.unusable`
# branch in `chain_artifact`, which is the only path that can produce it.
R="$(mk f4b-unusable-window 462)"
run "$R" 462 9001 "CI" 1; group "$R" 462 10 9001 "unit-test" completed success "$MERGED_AT"
printf '%s\t%s\t%s\t%s\n' 462 MERGED "not-a-timestamp" "$MERGE" > "$R/pr-462/pr.meta"
: > "$R/pr-462/chain.merged.unusable"
verify "$R"
ck "F4b: an unparseable mergedAt leaves the route UNKNOWN, never 'in window'" "$(has "could not be parsed into a usable timestamp"; echo $?)"
ck "F4b: …and the marker is NOT attributed to the chain" "$(has "landed by the per-PR chain" && echo 1 || echo 0)"

# P2 — round 6's P2: a re-run whose `started_at` is KNOWN and LATER than mergedAt is a post-merge job,
# not part of this gate. It used to be defaulted into `waited` ("the landing did not wait for it"),
# a FALSE FAIL whose verdict flipped the moment that four-hours-later job happened to finish. Both
# halves are asserted so the two buckets stay distinct: known-late ⇒ `later` ⇒ PASS; null ⇒ `waited`.
R="$(mk p2-run-started-after-merge 463)"
run "$R" 463 9001 "CI" 1
group "$R" 463 10 9001 "unit-test" completed   success "2026-11-12T05:00:00Z" "2026-11-12T04:59:00Z"
group "$R" 463 20 9001 "unit-test" in_progress -       "-"                "2026-11-12T09:30:00Z"
rail_land "$R" 463
verify "$R"; rc=$?
ck "P2: a re-run that began AFTER mergedAt is 'not part of this gate', not a FAIL" \
  "$(has "did not wait for" && echo 1 || echo 0)"
# the excluded attempt does NOT vote, so the group's standing verdict is still the green that gated the
# landing — the post-merge re-run can neither launder a red nor manufacture one.
ck "P2: …and the group's standing verdict is still the green that gated the landing" \
  "$(has "1 group(s) GREEN"; echo $?)"
ck "P2: …so a correctly green-gated landing is not failed (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"
# the mirror: the SAME shape with a null `started_at` (a queued run — the API leaves it null) is still
# fail-closed, because the absence of a timestamp is never read as "it did not exist".
R="$(mk p2b-run-queued-null-start 464)"
run "$R" 464 9001 "CI" 1
group "$R" 464 10 9001 "unit-test" completed success "2026-11-12T05:00:00Z" "2026-11-12T04:59:00Z"
group "$R" 464 20 9001 "unit-test" queued    -       "-"
verify "$R"; rc=$?
ck "P2b: a queued attempt with NO started_at is still 'did not wait for'" "$(has "did not wait for"; echo $?)"
ck "P2b: …so that landing is a FAIL (exit 1)" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# ROUND 8 — the fresh-context review at a0f941f22203, and the blocking finding the review before it
# raised on the SAME head and nothing had remedied. One case per defect, each in the direction that
# costs the most.
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# P2 — fix_round anchored on the FIRST `not-clean` and read the marker immediately after it, so a fix
# round that needed TWO rounds and converged (`not-clean@H1 → not-clean@H2 → clean@H3`, standing verdict
# clean at the PR tip) was reported `FAIL … the round did not converge` with exit 1, while the same
# report printed `PASS review_record verdict=clean`. A false FAIL on capstone condition 4, for the
# ordinary shape of a two-round PR. The anchor is the LAST refusal.
R="$(mk fix-round-two-rounds 476)"
H1="5555555555555555555555555555555555555555"; H2="6666666666666666666666666666666666666666"
{
  printf 'review recorded: reviews/476.json verdict=not-clean @ %s (o/r) findings=3\n' "$H1"
  printf 'review recorded: reviews/476.json verdict=not-clean @ %s (o/r) findings=1\n' "$H2"
  printf 'review recorded: reviews/476.json verdict=clean @ %s (o/r)\n' "$HEAD"
} > "$R/pr-476/body.txt"
printf '%s\n%s\n%s\n' "$H1" "$H2" "$HEAD" > "$R/pr-476/pr-commits.tsv"
run "$R" 476 9001 "CI" 1; group "$R" 476 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 476
verify "$R"; rc=$?
ck "fix-round-two-rounds: a two-round fix that CONVERGED is a fix_round PASS" "$(has "PASS  fix_round"; echo $?)"
ck "fix-round-two-rounds: …anchored on the LAST refusal" "$(has "not-clean@666666666666 was superseded by clean@111111111111"; echo $?)"
ck "fix-round-two-rounds: …never described as a round that did not converge" "$(has "did not converge" && echo 1 || echo 0)"
ck "fix-round-two-rounds: …so a converged two-round PR can close the capstone (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# P3 — a control byte in a snapshot-supplied field is escaped: `\` and `"` alone left every byte below
# 0x20 raw, and `json.load` refuses the evidence file (`Invalid control character at char 122`).
R="$(mk json-control-byte 477)"
printf '%s\t%s\t%s\t%s\n' 477 MERGED "$(printf '2026-11-12T05:05:55Z\001bad')" "$MERGE" > "$R/pr-477/pr.meta"
run "$R" 477 9001 "CI" 1; group "$R" 477 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R" --json
ck "json-control-byte: a control byte in a detail is escaped as \\u00XX, not emitted raw" \
  "$(hasj '\u0001bad'; echo $?)"
ck "json-control-byte: …so the evidence file still parses" \
  "$(printf '%s' "$OUTJ" | python3 -c 'import json,sys; json.load(sys.stdin)' >/dev/null 2>&1; echo $?)"

# P3 — the two snapshot modes are mutually exclusive, and saying so is the contract: the write target
# used to be silently ignored (never created, no word said), so an operator asking for an evidence
# directory got a verification with no artifact and nothing to notice it by.
OUTX="$(run_verify --from-snapshot "$T/clean" --write-snapshot "$T/neversnapshot" --repo "$REPO_FIXTURE" 2>&1)"; rcx=$?
ck "snapshot-modes: --from-snapshot with --write-snapshot is a USAGE error (exit 3), never a silent no-op" \
  "$([ "$rcx" -eq 3 ] && echo 0 || echo 1)"
ck "snapshot-modes: …and the refusal says which two flags conflict" \
  "$(grep -qF -- 'mutually exclusive' <<<"$OUTX"; echo $?)"
ck "snapshot-modes: …and no snapshot directory was written" "$([ -e "$T/neversnapshot" ] && echo 1 || echo 0)"

# BLOCKING, the false-PASS class — `review_record` admitted a COMMENT marker that the repo's own
# required check refuses. Three arms, because the admission has three states: an untrusted AUTHOR, a
# marker that cannot be SIGNED-VERIFIED where a key exists, and the signed, attested marker that IS
# evidence (which must keep working — a gate nobody can satisfy gets bypassed).
R="$(mk comment-untrusted-author 478)"
: > "$R/pr-478/body.txt"
comment "$R" 478 NONE "$(printf 'review recorded: reviews/478.json verdict=clean @ %s (o/r)\n' "$HEAD")"
run "$R" 478 9001 "CI" 1; group "$R" 478 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"; rc=$?
ck "comment-untrusted-author: a marker from author_association=NONE is REFUSED, not admitted" \
  "$(has "its author_association is NONE"; echo $?)"
ck "comment-untrusted-author: …never PASS review_record" "$(has "PASS  review_record" && echo 1 || echo 0)"
ck "comment-untrusted-author: …so the run exits 2, never 0" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

R="$(mk comment-unsigned-with-key 479)"
: > "$R/pr-479/body.txt"
comment "$R" 479 OWNER "$(printf 'review recorded: reviews/479.json verdict=clean @ %s (o/r)\n' "$HEAD")"
run "$R" 479 9001 "CI" 1; group "$R" 479 10 9001 "unit-test" completed success "$MERGED_AT"
VKEY="$TEST_KEY"; verify "$R"; rc=$?; VKEY=""
ck "comment-unsigned-with-key: where a gate key resolves, an UNSIGNED marker comment is refused" \
  "$(has "its sig= does not verify"; echo $?)"
ck "comment-unsigned-with-key: …never PASS review_record" "$(has "PASS  review_record" && echo 1 || echo 0)"
ck "comment-unsigned-with-key: …so the run exits 2, never 0" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

R="$(mk comment-signed 480)"
: > "$R/pr-480/body.txt"
MK="review recorded: reviews/480.json verdict=clean @ $HEAD (o/r)"
# ⛔ TWO comments on purpose: a real review thread has more than one, and the SECOND record is the one
# whose author field carries `jq -r`'s separator newline — the byte the reader must strip before it can
# read "OWNER". With a single comment this fixture could not tell a reader that strips from one that
# does not (measured: mutation M23 passed over it until this second comment existed).
comment "$R" 480 NONE "lgtm — not an attestation"
comment "$R" 480 OWNER "$(printf '%s\n' "$(sign_marker "$MK")")"
run "$R" 480 9001 "CI" 1; group "$R" 480 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 480
VKEY="$TEST_KEY"; verify "$R"; rc=$?; VKEY=""
ck "comment-signed: an ATTESTED, signed marker comment IS evidence" "$(has "PASS  review_record"; echo $?)"
ck "comment-signed: …and the detail names the arm that admitted it (auth=sig)" "$(has "auth=sig"; echo $?)"
ck "comment-signed: …so a correctly reviewed landing is not failed (exit 0)" "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# ══════════════════════════════════════════════════════════════════════════════════════════════
# ROUND 9 — the fresh-context review at fbe6f636a5. Two P2s IN THE PREDICATE (both false-PASS/false-FAIL
# by execution on fixtures of this suite's own shape), one P3 in a case of this file, and one P3 in the
# record-file fallback. Every case below FAILS on the pre-fix script — the mutations M24/M25/M26 prove it.
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# P2 — the marker sha was parsed with a GREEDY `^.* @ `, and the marker's TRAILER IS FREE TEXT:
# `record-review.sh` splices the recorder's FINDINGS_NOTE verbatim after the sha (only a quote, a
# backslash and control bytes are rejected), and that trailer exists ONLY on `not-clean` markers — so the
# markers the greedy parse ate were exactly the refusals whose loss flips the verdict. A note reading
# `refused @ round 1` left "round 1" as the sha, the 40-hex guard failed, and `next` dropped the marker
# SILENTLY: with the refusal at the same head as an earlier clean, the whole run said ALL-MET, exit 0.
R="$(mk marker-note-at 481)"
{
  printf 'review recorded: reviews/481.json verdict=clean @ %s (o/r)\n' "$HEAD"
  printf 'review recorded: reviews/481.json verdict=not-clean @ %s (o/r) findings=refused @ round 1\n' "$HEAD"
} > "$R/pr-481/body.txt"
run "$R" 481 9001 "CI" 1; group "$R" 481 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 481
verify "$R"; rc=$?
ck "marker-note-at: a refusal whose findings note carries ' @ ' is READ, not silently dropped" \
  "$(has "the standing record at head ${HEAD:0:12} is NOT-CLEAN"; echo $?)"
ck "marker-note-at: …so the clean at the same head never reads as the standing record" \
  "$(has "PASS  review_record" && echo 1 || echo 0)"
ck "marker-note-at: …and the run exits 1, never 0 (the false PASS this pin exists for)" \
  "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# P2 — the standing record was decided by CHANNEL, NOT BY RECENCY. The producer posts the evidence COMMENT
# first and the body best-effort (`record-review.sh:8420` `post_review_evidence_comment … || true`, then
# `post_marker`), so a body PATCH that failed — the exit-5 path the pending/flush machinery exists for —
# leaves the body STALE while the comment carries the newest record. Body `not-clean@H1` + comment
# `clean@H2` (H2 the tip) was reported NOT-CLEAN plus a "did not converge" fix_round, exit 1: the
# false-FAIL class the header says teaches readers to ignore the instrument.
R="$(mk record-newest-by-recency 482)"
H1C="3333333333333333333333333333333333333333"
printf '%s\n%s\n' "$H1C" "$HEAD" > "$R/pr-482/pr-commits.tsv"
printf 'review recorded: reviews/482.json verdict=not-clean @ %s (o/r) findings=1\n' "$H1C" > "$R/pr-482/body.txt"
comment "$R" 482 OWNER "$(printf 'review recorded: reviews/482.json verdict=clean @ %s (o/r)\n' "$HEAD")"
run "$R" 482 9001 "CI" 1; group "$R" 482 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 482
verify "$R"; rc=$?
ck "record-newest-by-recency: the NEWEST admitted record is the comment's clean at the tip" \
  "$(has "PASS  review_record" && has "head=${HEAD:0:12} source=marker-comment" && echo 0 || echo 1)"
ck "record-newest-by-recency: …so the stale body refusal was superseded, not the standing verdict" \
  "$(has "not-clean@${H1C:0:12} was superseded by clean@${HEAD:0:12}"; echo $?)"
ck "record-newest-by-recency: …and a correctly reviewed landing exits 0" \
  "$([ "$rc" -eq 0 ] && echo 0 || echo 1)"

# …and the TIEBREAK at an EQUAL head is UNCHANGED: the body is written LAST, so where both channels carry a
# marker at the same head the body is still the recorder's current word. (A regression pin rather than a
# mutation-covered case: the recency fix must not invert the rule it qualified.)
R="$(mk record-order-tiebreak 483)"
printf 'review recorded: reviews/483.json verdict=not-clean @ %s (o/r) findings=1\n' "$HEAD" > "$R/pr-483/body.txt"
comment "$R" 483 OWNER "$(printf 'review recorded: reviews/483.json verdict=clean @ %s (o/r)\n' "$HEAD")"
run "$R" 483 9001 "CI" 1; group "$R" 483 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"; rc=$?
ck "record-order-tiebreak: at an EQUAL head the body is still the standing record (NOT-CLEAN)" \
  "$(has "the standing record at head ${HEAD:0:12} is NOT-CLEAN"; echo $?)"
ck "record-order-tiebreak: …so the run exits 1" "$([ "$rc" -eq 1 ] && echo 0 || echo 1)"

# P3 — the box-local record file's `pr` field was used ONLY inside the signed text and never compared with
# the PR being verified, so a record legitimately signed for another PR in the same repo verified here
# whenever the head matched — and ONE HEAD CAN CARRY A STACK OF PRs. The gate binds the file to the PR by
# signing the CALLER's own PR number (`review_record_eval`), which is the check this reader was missing.
R="$(mk record-file-other-pr 484)"
: > "$R/pr-484/body.txt"
printf '{"pr":599,"head_sha":"%s","sig":"%s","verdict":"clean","repo":"o/r"}\n' \
  "$HEAD" "$(record_sig 599 "$HEAD" clean o/r)" > "$R/pr-484/record.json"
run "$R" 484 9001 "CI" 1; group "$R" 484 10 9001 "unit-test" completed success "$MERGED_AT"
VKEY="$TEST_KEY"; verify "$R"; rc=$?; VKEY=""
ck "record-file-other-pr: a record signed for ANOTHER PR is refused, naming the mismatch" \
  "$(has "minted for PR #599, not PR #484"; echo $?)"
ck "record-file-other-pr: …never PASS review_record" "$(has "PASS  review_record" && echo 1 || echo 0)"
ck "record-file-other-pr: …and the run exits 2, never 0" "$([ "$rc" -eq 2 ] && echo 0 || echo 1)"

# ════════════════════════════════════════════════════════════════════════════════════════════════
# THE LIVE FETCH PATH (fresh-context review, round 10 — BLOCKING, and the CLASS the rest of this
# suite was structurally blind to).
#
# ⛔ EVERY CASE ABOVE IS `--from-snapshot`, and every fixture HAND-WRITES `comments.txt` in the frame
# the READER wants — so `fetch_one`'s seven read expressions had ZERO coverage and the producer-side
# jq never executed. The P1 that survived nine rounds lived exactly there: the comment read was
# `pr view --json comments` (a JSON OBJECT in gh's camelCase spelling) carrying `REVIEW_COMMENTS_JQ`,
# which is written for REST `issues/<n>/comments` (ARRAY root, snake_case). `.[]` on an object is a
# jq RUNTIME error and `.author_association` does not exist under `pr view`, so the channel was
# unreadable on EVERY live run — `review_record`, `review_bound`, `fix_round` and `green_gated`
# INCONCLUSIVE, `VERDICT: ALL-MET` unreachable — while this suite stayed green.
#
# So this case drives the REAL script through a `gh` SHIM that serves each endpoint's REAL payload
# SHAPE and applies the `--jq` it is given with the REAL jq. A shim that pre-bakes the jq OUTPUT would
# grade nothing (it would encode the answer instead of exercising the expression), which is the same
# fixture-bypasses-the-transport defect one level up.
# ════════════════════════════════════════════════════════════════════════════════════════════════
live_payloads() { # live_payloads <dir> <pr> → writes the five raw endpoint payloads under <dir>
  local d="$1" pr="$2"
  # `gh pr view --json <fields>` — an OBJECT, camelCase (`authorAssociation`, `mergeCommit.oid`).
  # MEASURED on `gh` 2.x: `.comments[] | keys` = author, authorAssociation, body, createdAt, id, …
  # ⛔ THE BODY IS EMPTY ON PURPOSE. The BODY channel is read LAST (it is the recorder's current word),
  # so a marker in both would answer from the body and leave the COMMENT channel untested — the exact
  # channel the P1 made inert.
  cat > "$d/pr-view.json" <<EOF
{"number":$pr,"state":"MERGED","mergedAt":"$MERGED_AT","mergeCommit":{"oid":"$MERGE"},
 "body":"",
 "comments":[
  {"author":{"login":"daniel-ospina"},"authorAssociation":"OWNER",
   "body":"review recorded: reviews/$pr.json verdict=clean @ $HEAD (o/r)\n"},
  {"author":{"login":"stranger"},"authorAssociation":"NONE",
   "body":"a stranger passing through"}]}
EOF
  # `gh api repos/…/pulls/<n>/commits` — an ARRAY of commit objects (`.sha`).
  printf '[{"sha":"%s"}]\n' "$HEAD" > "$d/pr-commits.json"
  # `gh api repos/…/issues/<n>/comments` — an ARRAY, REST snake_case (`author_association`).
  cat > "$d/comments.json" <<EOF
[{"author_association":"OWNER",
  "body":"review recorded: reviews/$pr.json verdict=clean @ $HEAD (o/r)\n"},
 {"author_association":"NONE","body":"a stranger passing through"}]
EOF
  printf '{"sha":"%s","commit":{"tree":{"sha":"%s"}},"parents":[]}\n' \
    "$HEAD" "$HEAD_TREE" > "$d/commit.json"
  printf '{"workflow_runs":[{"id":9001,"name":"CI","run_attempt":1,"path":".github/workflows/ci.yml"}]}\n' \
    > "$d/runs.json"
  printf '{"total_count":1,"check_runs":[{"id":10,"app":{"slug":"github-actions"},"name":"unit-test","status":"completed","conclusion":"success","completed_at":"%s","details_url":"https://github.com/o/r/actions/runs/9001/job/1","started_at":"2026-11-12T04:00:00Z"}]}\n' \
    "$MERGED_AT" > "$d/checkruns.json"
}
gh_shim() { # gh_shim <payload-dir> → prints the path of a `gh` that serves those payloads
  local d="$1" shim="$T/gh-shim-$RANDOM"
  cat > "$shim" <<'SHIM'
#!/usr/bin/env bash
# gh shim — answers only the read shapes `fetch_one` issues, serves the REAL payload shape for each,
# and runs the `--jq` it was GIVEN through the real jq so the expression under test actually executes.
set -u
jqexpr=""; args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --jq)       jqexpr="$2"; shift 2 ;;
    --paginate) shift ;;
    --repo|--json) shift 2 ;;
    *)          args+=("$1"); shift ;;
  esac
done
payload=""
case "${args[0]:-} ${args[1]:-}" in
  "pr view"*) payload="$SHIM_PAYLOAD/pr-view.json" ;;
  "api "*"comments"*)  payload="$SHIM_PAYLOAD/comments.json" ;;
  "api "*"pulls/"*"commits"*) payload="$SHIM_PAYLOAD/pr-commits.json" ;;
  "api "*"check-runs"*) payload="$SHIM_PAYLOAD/checkruns.json" ;;
  "api "*"actions/runs"*) payload="$SHIM_PAYLOAD/runs.json" ;;
  "api "*"commits/"*) payload="$SHIM_PAYLOAD/commit.json" ;;
  *) printf 'gh-shim: unexpected read: %s\n' "$*" >&2; exit 1 ;;
esac
if [ -n "$jqexpr" ]; then jq -r "$jqexpr" < "$payload"; else cat "$payload"; fi
SHIM
  chmod +x "$shim"
  printf '%s\n' "$shim"
}

if ! command -v jq >/dev/null 2>&1; then
  printf '  \033[33mSKIP\033[0m  the live-fetch cases: no `jq` on this box, so the producer-side expressions cannot be executed (the fetch path needs jq in production too)\n'
else
  PAY="$T/live-payloads"; mkdir -p "$PAY"
  live_payloads "$PAY" 501
  SHIM="$(gh_shim "$PAY")"
  # ⛔ THE FIXTURE IS THE REAL SHAPE, AND THE MUTATION IT WOULD HAVE PASSED IS MEASURED HERE. These two
  # assertions are what make the case below non-vacuous: if the payload were shaped to suit the OLD
  # expressions, the case would prove nothing about the live path.
  jq -r '.[] | "\(.author_association)"' < "$PAY/pr-view.json" >/dev/null 2>&1
  ck "live-fetch fixture: \`.[]\` on \`pr view\`'s payload is a jq RUNTIME error (the object root, measured — the P1's first half)" \
    "$([ $? -ne 0 ] && echo 0 || echo 1)"
  ck "live-fetch fixture: \`.author_association\` under \`pr view\` reads null (camelCase \`authorAssociation\` — the P1's second half)" \
    "$(jq -r '.comments[0] | "[\(.author_association)]"' < "$PAY/pr-view.json" | grep -qxF '[null]'; echo $?)"

  LIVE="$T/live"; mkdir -p "$LIVE"
  SHIM_PAYLOAD="$PAY" AGENT_GH_REAL="$SHIM" HOME="$T/home" AI_REVIEW_GATE_KEY="" \
    bash "$SCRIPT" 501 --repo "$REPO_FIXTURE" --write-snapshot "$LIVE" > "$T/live.out" 2>&1; livrc=$?
  ck "live-fetch: the comment channel is READ on a live-shaped payload (no comments.txt.unread sentinel)" \
    "$([ -e "$LIVE/pr-501/comments.txt.unread" ] && echo 1 || echo 0)"
  ck "live-fetch: …so the run does NOT report the channel as unread" \
    "$(grep -qF 'were NOT READ' "$T/live.out" && echo 1 || echo 0)"
  # the ASSOCIATION has to travel with the body, or the admission rule cannot be applied at all
  ck "live-fetch: the association travels in the producer frame (an 0x1f separator precedes the body)" \
    "$(grep -q "$(printf '\037')" "$LIVE/pr-501/comments.txt" && echo 0 || echo 1)"
  ck "live-fetch: …and a trusted author is admitted while an untrusted one still travels as NONE" \
    "$(grep -q 'OWNER' "$LIVE/pr-501/comments.txt" && grep -q 'NONE' "$LIVE/pr-501/comments.txt"; echo $?)"
  OUTL="$(HOME="$T/home" AI_REVIEW_GATE_KEY="" bash "$SCRIPT" --from-snapshot "$LIVE" --repo "$REPO_FIXTURE" 2>&1)"; livrc2=$?
  ck "live-fetch: the marker admitted from the LIVE payload satisfies review_record" \
    "$(grep -qF 'PASS  review_record' <<<"$OUTL"; echo $?)"
  ck "live-fetch: …naming the COMMENT channel as its source" \
    "$(grep -qF 'source=marker-comment' <<<"$OUTL"; echo $?)"
  # review_bound is one of the four predicates the unread short-circuit suppressed, so it is the
  # second independent witness that the channel is live (a single PASS could come from the body).
  ck "live-fetch: …and review_bound PASSes too (the second predicate the unread short-circuit suppressed)" \
    "$(grep -qF 'PASS  review_bound' <<<"$OUTL"; echo $?)"

  # ⛔ THE FILTER AND ITS ENDPOINT ARE ONE DECISION, SO THEY ARE PINNED TOGETHER (drift pin). The gate
  # and this verifier must read ONE artifact in ONE frame; the P1 was a filter copied without its
  # endpoint. Nothing else in this repo compares the two, so a future edit to either alone is invisible.
  _gate_jq="$(sed -nE "s/^REVIEW_COMMENTS_JQ='(.*)'\$/\\1/p" "$HERE/../check-pipeline-compliance.sh" | head -1)"
  _vlc_jq="$(grep -F -- "--jq '.[] | \"\\(.author_association)" "$SCRIPT" | head -1 \
    | sed -e "s/^[[:space:]]*--jq '//" -e "s/'[[:space:]]*\$//")"
  ck "drift pin: this verifier's comment-frame jq is non-empty and present" "$([ -n "$_vlc_jq" ] && echo 0 || echo 1)"
  ck "drift pin: …and BYTE-IDENTICAL to check-pipeline-compliance.sh's REVIEW_COMMENTS_JQ (one filter, one frame)" \
    "$([ -n "$_gate_jq" ] && [ "$_gate_jq" = "$_vlc_jq" ] && echo 0 || echo 1)"
  ck "drift pin: …and it is issued against the SAME endpoint the gate reads (issues/<n>/comments, not pr view)" \
    "$(grep -qF 'api "repos/$REPO/issues/$pr/comments' "$SCRIPT"; echo $?)"

fi

# ════════════════════════════════════════════════════════════════════════════════════════════════
# The MARKER-PREFIX STRIP (fresh-context review, round 10 — P3). `\x2d` is a GAWK hex escape, not
# POSIX ERE: where `\x` is not one, the class silently becomes `[[:space:]>*+x]`, so a marker written as
# a LIST ITEM keeps its `-`, misses the `index(line, "review recorded: …") != 1` guard and is dropped as
# INCONCLUSIVE — while a line starting with the letter `x` IS stripped. Both directions measured under
# `gawk --posix`. The `-` belongs in LAST position, where it is literal everywhere.
# ════════════════════════════════════════════════════════════════════════════════════════════════
R="$(mk comment-list-item 490)"
: > "$R/pr-490/body.txt"
comment "$R" 490 OWNER "$(printf -- '- review recorded: reviews/490.json verdict=clean @ %s (o/r)\n' "$HEAD")"
run "$R" 490 9001 "CI" 1; group "$R" 490 10 9001 "unit-test" completed success "$MERGED_AT"
verify "$R"; rc=$?
ck "comment-list-item: a marker written as a LIST ITEM is admitted (the strip exists to tolerate it)" \
  "$(has 'PASS  review_record'; echo $?)"
ck "comment-list-item: …from the comment channel" "$(has 'source=marker-comment'; echo $?)"

# the ACTUAL shipped regex, executed — never a copy of it, or the case would grade prose
_SUBLINE="$(grep -F 'sub(/^[[:space:]>*+' "$SCRIPT" | head -1)"
ck "marker-prefix strip: the rule is present in the source and is the ONLY one (mutation site is real)" \
  "$([ -n "$_SUBLINE" ] && echo 0 || echo 1)"
case "$_SUBLINE" in
  *'\x'*) ck "marker-prefix strip: uses no \`\\x\` escape inside the character class (gawk-only — a POSIX awk strips \`x\` instead of \`-\`)" 1 ;;
  *)       ck "marker-prefix strip: uses no \`\\x\` escape inside the character class (gawk-only — a POSIX awk strips \`x\` instead of \`-\`)" 0 ;;
esac
_POSIX_AWK=""
if command -v gawk >/dev/null 2>&1; then _POSIX_AWK="gawk --posix"
elif printf 'x\n' | awk --posix '{ print }' >/dev/null 2>&1; then _POSIX_AWK="awk --posix"; fi
if [ -n "$_POSIX_AWK" ]; then
  _P="$(printf -- '- review recorded: x\nx review recorded: y\n' \
    | $_POSIX_AWK "{ line=\$0; $_SUBLINE; print \"[\" line \"]\" }" 2>&1)"
  ck "marker-prefix strip under a POSIX-forcing awk: a leading \`-\` IS stripped" \
    "$(grep -qxF '[review recorded: x]' <<<"$_P" && echo 0 || echo 1)"
  ck "marker-prefix strip under a POSIX-forcing awk: …and a leading \`x\` is NOT (the \`\\x\` collapse, measured)" \
    "$(grep -qxF '[x review recorded: y]' <<<"$_P" && echo 0 || echo 1)"
else
  printf '  \033[33mSKIP\033[0m  the POSIX-awk dialect arm: neither \`gawk\` nor \`awk --posix\` is on this box (the source invariant above still holds everywhere)\n'
fi

# ── MUTATIONS: prove every case above is DISCRIMINATING, not merely green ───────────────────────
# ⛔ A suite that passes over BOTH the real script and a deliberately wrong one asserts nothing. Each
# mutation below breaks exactly the decision one case exists for; the case must then FLIP. This is the
# same non-vacuity discipline `tools/fleet/outcome_canary.test.py --mutations` applies, and the reason
# it is here: two of the three mutations are defects this file actually shipped with for one round
# (tree equality instead of final-commit binding; the re-run read as "newest overall").
# ⛔ THE MUTANT MUST BE ABLE TO RUN (fresh-context review, round 2 F1 — MEASURED). The first cut copied
# ONE file into a fresh directory, so the copy could not source its sibling `repo-slug.sh`, refused
# with exit 3 BEFORE any predicate, and every mutation below "passed" by ABSENCE — a non-vacuity proof
# that proved nothing, which is the same class as the defect it was written to rule out. The sibling
# module comes with it now, and `verify_with` reports the mutant's EXIT STATUS so a mutant that cannot
# run is a FAILED mutation rather than a discriminating one.
mutant() { # mutant <name> <python-old> <python-new> → prints the path of a mutated copy
  local d="$MUT/$1"
  mkdir -p "$d"
  cp "$SCRIPT" "$d/verify-landing-chain.sh"
  # everything the script sources or reads from its own directory
  for sib in "$HERE"/repo-slug.sh; do [ -f "$sib" ] && cp "$sib" "$d/"; done
  python3 - "$d/verify-landing-chain.sh" "$2" "$3" <<'PYEOF' || return 1
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
s = open(path).read()
if s.count(old) != 1:
    sys.stderr.write("mutation site not found exactly once (%d)\n" % s.count(old)); sys.exit(1)
open(path, "w").write(s.replace(old, new))
PYEOF
  printf '%s\n' "$d/verify-landing-chain.sh"
}
verify_with() { # verify_with <script> <root> [--json] → sets AOUT (report) and AOUT_RC (the mutant's exit)
  # ⛔ THE REFERENCE RUN IS TAKEN HERE, ON THE SAME FIXTURE AND THE SAME MODE (round 9 F1). `mutation_verdict`
  # needs the CORRECT script's output to check its own premise against, and it must be the same invocation
  # or the premise is about a different code path — which is exactly how M18 came to be measured on a run
  # where the mutated code never executed.
  local jarg=""
  case "${3:-}" in --json) jarg="--json" ;; esac
  if [ -n "$jarg" ]; then
    _ref_run --from-snapshot "$2" --repo "$REPO_FIXTURE" --json
    AOUT="$(HOME="$T/home" AI_REVIEW_GATE_KEY="$VKEY" bash "$1" --from-snapshot "$2" --repo "$REPO_FIXTURE" --json 2>&1)"
  else
    _ref_run --from-snapshot "$2" --repo "$REPO_FIXTURE"
    AOUT="$(HOME="$T/home" AI_REVIEW_GATE_KEY="$VKEY" bash "$1" --from-snapshot "$2" --repo "$REPO_FIXTURE" 2>&1)"
  fi
  AOUT_RC=$?
}
# ⛔ THE REFERENCE IS THE CORRECT SCRIPT, ONCE PER (fixture, mode, key) — NOT per mutation: the same
# fixture is measured by several mutations and a fresh run each time would add minutes to the shard.
REFOUT=""; REF_SEEN=""
_ref_run() { # _ref_run <args to the CORRECT script…> → sets REFOUT, REFRC, REF_SEEN (cached)
  local key f
  key="$(printf '%s|%s' "$VKEY" "$*" | cksum | awk '{print $1}')"
  f="$MUT/_ref/$key"
  if [ ! -f "$f.out" ]; then
    mkdir -p "$MUT/_ref"
    HOME="$T/home" AI_REVIEW_GATE_KEY="$VKEY" bash "$SCRIPT" "$@" > "$f.out" 2>&1
    printf '%s\n' "$?" > "$f.rc"
  fi
  REFOUT="$(cat "$f.out")"; REFRC="$(cat "$f.rc")"; REF_SEEN=1
}
# A mutant that did not produce a REPORT proves nothing. 0/1/2 are the verdict ladder; 3 is usage and
# anything else is a crash. Both are reported as an invalid mutation, never as discrimination.
# ⛔ `--json` PRINTS NO `PR #` HEADER (round 9 F1): the JSON emitter opens with `{"prs":[`, so the report
# header test accepts either rendering. Without this a JSON-driven mutation could never run — which is one
# reason M18 was driven through the TEXT renderer, where its mutation site does not execute at all.
mutant_ran() {
  case "${AOUT_RC:-3}" in
    0|1|2) grep -q -e '^PR #' -e '^{"prs":' <<<"$AOUT" ;;
    *) return 1 ;;
  esac
}

# ⛔ ONE SHAPE FOR EVERY MUTATION, AND IT CANNOT PASS BY ABSENCE. `mutation_verdict` refuses a mutant
# that did not run (rc outside the 0/1/2 verdict ladder, or no report header in its output) as an
# INVALID mutation — that is exactly how round 1's six mutations came to prove nothing, so the guard
# is not optional here.
# ⛔ …AND IT CHECKS ITS OWN PREMISE (fresh-context review, round 9 — F1, reproduced by execution). It used
# to grep the needle ONLY in the mutant's output, so a needle the CORRECT run never prints was absent in
# BOTH runs and the `else` arm reported "discriminating" for a fact nobody measured. That is an
# EQUIVALENT MUTANT — identical output on the inputs exercised, so it can never be killed (Stryker
# Mutator, "Equivalent mutants") — and it is how M14 (round 7) and M18 (round 8) both shipped green while
# proving nothing. The needle is now REQUIRED in the correct script's output on the same fixture and mode
# first (`REFOUT`, taken by `verify_with`/`_ref_run`); absent there, the mutation is INVALID.
# The needle is a string the CORRECT script prints in this scenario; the mutant must lose it.
mutation_verdict() { # mutation_verdict <label> <needle-the-correct-script-prints> <what-broke>
  if ! mutant_ran; then
    bad "$1: INVALID MUTATION — the mutant did not produce a report (rc=${AOUT_RC:-?}), so nothing is proven"
    return
  fi
  if [ -z "$REF_SEEN" ] || ! grep -qF -- "$2" <<<"$REFOUT"; then
    bad "$1: INVALID MUTATION — the CORRECT script does not print '$2' on this fixture and mode, so its absence from the mutant is an EQUIVALENT MUTANT, not discrimination"
    return
  fi
  if grep -qF -- "$2" <<<"$AOUT"; then
    bad "$1: the mutant STILL printed '$2' — the case is not discriminating"
  else
    ok "$1: $3"
  fi
}

# ⛔ THE PREMISE CHECK IS ITSELF CHECKED (round 9 F1). A needle the CORRECT run never prints must be
# reported INVALID, never as discrimination — otherwise the new guard is the same green-by-absence shape it
# exists to remove. Run in a SUBSHELL so its own ok()/bad() cannot move this suite's counters (a subshell
# increments its own copies); only the TEXT it emitted is asserted here.
verify_with "$SCRIPT" "$T/clean"
_SELF="$(mutation_verdict M0 "a sentence this fixture never prints — the equivalent-mutant alibi" "must never be reported as discrimination" 2>&1)"
ck "mutation_verdict refuses a needle the CORRECT run never prints (round 9 F1: the equivalent-mutant alibi)" \
  "$(grep -qF 'INVALID MUTATION — the CORRECT script does not print' <<<"$_SELF"; echo $?)"
ck "…and it does NOT report that mutation as discriminating" \
  "$(grep -qF 'must never be reported as discrimination' <<<"$_SELF" && echo 1 || echo 0)"

# M1 — group by JOB NAME alone (drop the workflow). Case 8 must stop seeing the red.
MS="$(mutant name-only 'g = w "/" name' 'g = name')" || bad "M1 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-name-only 430)"
run "$R" 430 9001 "Workflow A" 1; run "$R" 430 9002 "Workflow B" 1
group "$R" 430 20 9002 "packaging-smoke" completed failure "2026-11-12T04:00:00Z"
group "$R" 430 30 9001 "packaging-smoke" completed success "2026-11-12T04:10:00Z"
verify_with "$MS" "$R"
mutation_verdict M1 "Workflow B/packaging-smoke:failure" \
  "grouping by the job name alone loses the red — case 8 is discriminating"

# M2 — read the newest attempt OVERALL instead of the newest one that existed by mergedAt.
# ⛔ THE MUTATION TARGET MOVED IN ROUND 6 (the `existed` expression was rewritten for P2), and its
# MEANING is narrower than it says: since round 5's `voted_by_merge`, admitting a later attempt can no
# longer launder a verdict into GREEN — what it flips is the SENTENCE (a red landing explained as "a
# green arrived late" instead of the red it was). M12 below is the pin on the VERDICT path. Both are
# needed, and a reader must not think this one covers the exit code.
MS="$(mutant newest-overall 'existed = (voted_by_merge ||' 'existed = (1 ||')" || bad "M2 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-newest-overall 431)"
run "$R" 431 9001 "CI" 1
group "$R" 431 10 9001 "pipeline-compliance" completed failure "2026-11-12T04:41:17Z"
group "$R" 431 20 9001 "pipeline-compliance" completed success "2026-11-12T05:24:50Z"
verify_with "$MS" "$R"
mutation_verdict M2 "completed AFTER mergedAt" \
  "reading the newest attempt overall changes the reason a red landing is explained — case 6 is discriminating"

# M3 — bind on TREE EQUALITY instead of the PR's final commit (the #3996 FALSE FAIL).
MS="$(mutant tree-equality 'if [ "$last_commit" = "$rsha" ]; then' 'if [ "$(tree_of "$dir/commit-${rsha}.tsv")" = "$landed_tree" ]; then')" \
  || bad "M3 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-tree-equality 432)"
run "$R" 432 9001 "CI" 1; group "$R" 432 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 432
verify_with "$MS" "$R"
mutation_verdict M3 "IS the PR's final commit" \
  "tree equality fails a correct landing (the #3996 defect) — case 3 is discriminating"

# M4 — collapse "existing but had not voted by the merge" back into the harmless bucket (round 2's F2).
MS="$(mutant f1-collapse 'v = (ncls[g] == "pending" ? "waited" : ncls[g])' 'v = (ncls[g] == "pending" ? "later" : ncls[g])')" \
  || bad "M4 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-waited 433)"
run "$R" 433 9001 "CI" 1
group "$R" 433 10 9001 "unit-test"    completed success "2026-11-12T04:00:00Z"
group "$R" 433 20 9001 "vendor-drift" in_progress -     "-"
verify_with "$MS" "$R"
mutation_verdict M4 "did not wait for" \
  "a queued/in-flight group becomes PASS-eligible and green-lights the landing — F1/round-2-F2 is discriminating"

# M5 — do not HONOUR the sentinel (round 1's F2): an unread surface degrades to a measured zero.
MS="$(mutant f2-ignore-sentinel 'if [ -f "$dir/checkruns-${rsha}.tsv.unread" ] || [ -f "$dir/runs-${rsha}.tsv.unread" ]; then' 'if [ 0 -eq 1 ]; then')" \
  || bad "M5 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-unread 434)"
run "$R" 434 9001 "CI" 1
: > "$R/pr-434/checkruns-$HEAD.tsv"
: > "$R/pr-434/checkruns-$HEAD.tsv.unread"
verify_with "$MS" "$R"
mutation_verdict M5 "was NOT READ" \
  "ignoring the sentinel degrades an unread surface to 'measured zero' — case F2a is discriminating"

# M6 — admit a marker that names ANOTHER repo (round 1's F3): PR numbers collide across repos.
MS="$(mutant f3-no-repo-filter 'if (tolower(repo) != fold) { printf "SKIP' 'if (0) { printf "SKIP')" \
  || bad "M6 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-foreign-marker 435)"
: > "$R/pr-435/body.txt"
comment "$R" 435 OWNER "$(printf 'review recorded: reviews/435.json verdict=clean @ %s (someone-else/other-repo)\n' "$HEAD")"
run "$R" 435 9001 "CI" 1; group "$R" 435 10 9001 "unit-test" completed success "$MERGED_AT"
verify_with "$MS" "$R"
mutation_verdict M6 "refused as naming another repo" \
  "without the repo filter a foreign marker reads as this PR's review — case F3 is discriminating"

# M8 — fold "a green completed before the merge" into "a green arrived late" (round 3's F1): the red
# landing is explained away as a timing artifact instead of "a newer attempt was RED".
MS="$(mutant f1r-collapse-green-timing 'else green_before[g] = 1' 'else green_late[g] = 1')" \
  || bad "M8 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-green-timing 452)"
run "$R" 452 9001 "CI" 1
group "$R" 452 10 9001 "unit-test" completed success "2026-11-12T04:00:00Z"
group "$R" 452 20 9001 "unit-test" completed failure "2026-11-12T04:30:00Z"
verify_with "$MS" "$R"
mutation_verdict M8 "a green DID complete before mergedAt" \
  "collapsing the green timing blames the clock for a red landing — case F1r is discriminating"

# M10 — PASS a record whose verdict is `not-clean` (round 4's F2): the false PASS.
MS="$(mutant f2-not-clean-passes '        emit review_record FAIL "the standing record at head' '        emit review_record PASS "the standing record at head')" \
  || bad "M10 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-not-clean 458)"
run "$R" 458 9001 "CI" 1; group "$R" 458 10 9001 "unit-test" completed success "$MERGED_AT"
printf '<<<BODY>>>\nreview recorded: reviews/458.json verdict=not-clean @ %s (o/r)\n' "$HEAD" > "$R/pr-458/body.txt"
verify_with "$MS" "$R"
mutation_verdict M10 "FAIL  review_record" \
  "a standing not-clean is not a review record — case F2n is discriminating"

# M11 — let an older green outvote the newest in-flight attempt (round 4's F3).
MS="$(mutant f3-newest-voting-wins 'if (existed && (!(g in nid) || id > nid[g])) {' 'if (voted_by_merge && (!(g in nid) || id > nid[g])) {')" \
  || bad "M11 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-newest-voting 459)"
run "$R" 459 9001 "CI" 1
group "$R" 459 10 9001 "unit-test" completed   success "2026-11-12T04:00:00Z" "2026-11-12T03:59:00Z"
group "$R" 459 20 9001 "unit-test" in_progress -       "-"                "2026-11-12T05:00:00Z"
verify_with "$MS" "$R"
mutation_verdict M11 "did not wait for" \
  "counting only voting attempts hides the in-flight newest one — case F3n is discriminating"

# M12 — classify a not-yet-voted attempt by its POST-merge conclusion (round 5's F1, the false PASS).
MS="$(mutant f1t-post-merge-verdict '        if (voted_by_merge) { ncls[g] = classify(status, conc); nconc[g] = conc }' '        if (1) { ncls[g] = classify(status, conc); nconc[g] = conc }')" \
  || bad "M12 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-post-merge 461)"
run "$R" 461 9001 "CI" 1
group "$R" 461 10 9001 "pipeline-compliance" completed success "2026-11-12T04:41:17Z" "2026-11-12T04:40:00Z"
group "$R" 461 20 9001 "pipeline-compliance" completed success "2026-11-12T05:24:50Z" "2026-11-12T05:00:00Z"
verify_with "$MS" "$R"
mutation_verdict M12 "did not wait for" \
  "a re-run's post-merge conclusion must not gate the landing — case F1t is discriminating"

# M9 — drop the rail_landed row on the unread-record path (round 3, note 2): a 5-row report.
MS="$(mutant unread-drops-route '    emit_rail_landed "$dir" "$pr" "$merged"' '    :')" \
  || bad "M9 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-unread-route 453)"
run "$R" 453 9001 "CI" 1; group "$R" 453 10 9001 "unit-test" completed success "$MERGED_AT"
rail_land "$R" 453
: > "$R/pr-453/body.txt"; : > "$R/pr-453/body.txt.unread"
verify_with "$MS" "$R"
mutation_verdict M9 "PASS  rail_landed" \
  "the unread path still reports the one route artifact can answer — case F3c-route is discriminating"

# M7 — read through the unread RECORD channel (round 2's F3): the comment marker must not be promoted.
MS="$(mutant record-unread-passthrough '  if [ -n "$rc_unread" ]; then' '  if [ 0 -eq 1 ]; then')" \
  || bad "M7 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-record-unread 436)"
rail_land "$R" 436
run "$R" 436 9001 "CI" 1; group "$R" 436 10 9001 "unit-test" completed success "$MERGED_AT"
: > "$R/pr-436/body.txt"
: > "$R/pr-436/body.txt.unread"
comment "$R" 436 OWNER "$(printf 'review recorded: reviews/436.json verdict=clean @ %s (o/r)\n' "$HEAD")"
verify_with "$MS" "$R"
mutation_verdict M7 "were NOT READ" \
  "reading through an unread body promotes a weaker comment marker — case F3c is discriminating"

# M13 — decide `rail_landed` on the FILE's presence again (round 6's P1, the false PASS that survived
# five rounds because no case ever put a refusal in `rail.out`). The mutant accepts ANY non-empty
# artifact as carrying a landing and swallows the chain FAIL underneath it.
MS="$(mutant rail-presence '    grep -qE "admin-merge: .*merged PR #${pr}([^0-9]|$)" "$f" 2>/dev/null || continue' '    grep -qE "admin-merge: .*merged PR #${pr}([^0-9]|$)" "$f" 2>/dev/null || :')" \
  || bad "M13 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-rail-presence 465)"
run "$R" 465 9001 "CI" 1; group "$R" 465 10 9001 "unit-test" completed success "$MERGED_AT"
printf 'admin-merge: ✅ PR #465 is ALREADY MERGED (state=MERGED, mergedAt=%s) — duplicate execution is a NO-OP: no CI work, no evidence comment, no merge attempt\n' "$MERGED_AT" > "$R/pr-465/rail.out"
: > "$R/pr-465/chain.merged"
verify_with "$MS" "$R"
mutation_verdict M13 "landed by the per-PR chain, not by auto-rail" \
  "file presence reads a no-op attempt as a landing and MASKS the chain FAIL — case route-refused-then-chain is discriminating"

# M14 — drop the known-late `started_at` guard (round 6's P2): a re-run created AFTER the merge is
# pulled back into `waited` and a correctly green-gated landing is reported FAIL.
# ⛔ THE NEEDLE WAS VACUOUS UNTIL ROUND 7 (fresh-context review, finding 2). It was
# `"not part of this gate"`, a sentence this scenario NEVER prints: it is appended only from the
# `later` bucket (groups with NO admitted attempt), and here the id-10 success completed 05:00 ≤ a
# 05:05:55 merge, so the group's standing verdict is `green` and nothing is `later`. The mutant's grep
# missed a string that was ABSENT FROM THE CORRECT RUN TOO, so `mutation_verdict` reported
# "discriminating" without ever proving the mutant differs from the correct script. The needle is now
# a line the correct run PRINTS and the mutant LOSES.
MS="$(mutant p2-started-late '      started_late = (started_at != "-" && started_at != "" && started_at > merged)' '      started_late = 0')" \
  || bad "M14 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-started-late 466)"
run "$R" 466 9001 "CI" 1
group "$R" 466 10 9001 "unit-test" completed   success "2026-11-12T05:00:00Z" "2026-11-12T04:59:00Z"
group "$R" 466 20 9001 "unit-test" in_progress -       "-"                "2026-11-12T09:30:00Z"
verify_with "$MS" "$R"
mutation_verdict M14 "1 group(s) GREEN" \
  "ignoring a known post-merge start FAILs a landing that was gated correctly — case P2 is discriminating"

# M15 — drop the UNUSABLE-window branch (round 6's P3): an unparseable `mergedAt` falls back to
# "no artifact on this box", which is a different, wrong answer — the marker EXISTS and cannot be
# attributed, and the report must say so.
MS="$(mutant rail-unusable-branch '  elif [ -f "$dir/chain.merged.unusable" ] || [ -f "$dir/chain.verdict.unusable" ] || [ -f "$dir/merge.log.unusable" ]; then' '  elif [ 0 -eq 1 ]; then')" \
  || bad "M15 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-rail-unusable 467)"
run "$R" 467 9001 "CI" 1; group "$R" 467 10 9001 "unit-test" completed success "$MERGED_AT"
printf '%s\t%s\t%s\t%s\n' 467 MERGED "not-a-timestamp" "$MERGE" > "$R/pr-467/pr.meta"
: > "$R/pr-467/chain.merged.unusable"
verify_with "$MS" "$R"
mutation_verdict M15 "could not be parsed into a usable timestamp" \
  "an unusable window is reported as an absent artifact unless its own branch exists — case F4b is discriminating"

# M16 — read a landing line in the CHAIN's own artifacts as an auto-rail landing (round 7's finding
# 1): `merge.log` is the per-PR chain's log and `merge-one.sh` pipes the rail's own stdout into it, so
# this is exactly the false PASS that reported every CHAIN landing as "the rail landed it on its own"
# and left the chain FAIL unreachable.
MS="$(mutant chain-log-as-rail '      chain_landing="${f##*/}"' '      landed_file="${f##*/}"')" \
  || bad "M16 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
R="$(mk mut-chain-log-as-rail 471)"
run "$R" 471 9001 "CI" 1; group "$R" 471 10 9001 "unit-test" completed success "$MERGED_AT"
printf 'admin-merge: ✅ merged PR #471 at %s (state=MERGED confirmed via the API; branch head was %s…)\n' \
  "$MERGE" "${HEAD:0:12}" > "$R/pr-471/merge.log"
verify_with "$MS" "$R"
mutation_verdict M16 "landed by the per-PR chain, not by auto-rail" \
  "a chain landing's own log reads as an auto-rail landing — case route-chain-mergelog-alone is discriminating"

# M17 — anchor the fix round on the FIRST refusal and treat the marker immediately after it as
# terminal (round 8's P2, the false FAIL on a converged two-round fix — the pre-fix reader, verbatim).
MS="$(mutant fix-round-first-anchor '          last = 0
          for (i = 1; i <= NR; i++) if (v[i] == "not-clean") last = i
          bad = s[last]
          # later, not merely different: a clean marker AFTER the last refusal, at another head
          for (i = last + 1; i <= NR; i++)' '          last = 0
          for (i = 1; i <= NR; i++) if (v[i] == "not-clean" && last == 0) last = i
          bad = s[last]
          for (i = last + 1; i <= last + 1 && i <= NR; i++)')" \
  || bad "M17 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
verify_with "$MS" "$T/fix-round-two-rounds"
mutation_verdict M17 "was superseded by clean@111111111111" \
  "anchoring on the FIRST refusal fails a converged two-round fix — case fix-round-two-rounds is discriminating"

# M18 — stop escaping control bytes (round 8's P3): the evidence file becomes invalid JSON.
# ⛔ DRIVEN THROUGH `--json` (fresh-context review, round 9 — F1, reproduced by execution). The mutation
# site is `jstr`, which exists ONLY in the `--json` emitter (`:1168`), and this block used to call
# `verify_with` with NO `--json`: the mutant differed from the correct script only in code that never ran,
# its TEXT report was BYTE-IDENTICAL to the correct one, the needle was absent from BOTH, and M18 printed
# "case json-control-byte is discriminating" — a fact nobody measured. That is an EQUIVALENT MUTANT
# (Stryker: identical output on the inputs exercised, so it can never be killed), the class round 7's
# finding 2 removed from M14, and `mutation_verdict` now refuses it outright as an INVALID mutation.
MS="$(mutant json-no-control-escape '        else if (c in CTL)    o = o "\\u00" CTL[c]' '        else if (0)           o = o "\\u00" CTL[c]')" \
  || bad "M18 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
verify_with "$MS" "$T/json-control-byte" --json
mutation_verdict M18 '\u0001bad' \
  "an unescaped control byte makes the --json evidence file unparseable — case json-control-byte is discriminating"

# M24 — decide the standing record by CHANNEL again (round 9's P2): the stale body refusal wins.
# The mutation drops the commit-position term, leaving only the channel tiebreak — the pre-fix reader.
MS="$(mutant record-by-channel '      i = ($4 in idx) ? idx[$4] : 0' '      i = 0')" \
  || bad "M24 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
verify_with "$MS" "$T/record-newest-by-recency"
mutation_verdict M24 "verdict=clean head=111111111111 source=marker-comment" \
  "channel priority reads a STALE body refusal as the standing record — case record-newest-by-recency is discriminating"

# M25 — parse the sha with the GREEDY `^.* @ ` again (round 9's P2): a refusal whose note carries ` @ `
# is dropped silently, and a clean at the same head reads as the standing verdict.
MS="$(mutant marker-sha-greedy '      s = rest; sub(/^[^ \t]+ @ /, "", s)' '      s = rest; sub(/^.* @ /, "", s)')" \
  || bad "M25 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
verify_with "$MS" "$T/marker-note-at"
mutation_verdict M25 "the standing record at head 111111111111 is NOT-CLEAN" \
  "a findings note containing ' @ ' drops the refusal and the clean reads as the record — case marker-note-at is discriminating"

# M26 — admit the box-local record file without comparing its `pr` field again (round 9's P3): a record
# signed for another PR at the same head reads as this PR's review.
MS="$(mutant record-file-any-pr '    elif [ "$recpr" != "$pr" ]; then' '    elif [ 0 -ne 0 ]; then')" \
  || bad "M26 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
VKEY="$TEST_KEY"; verify_with "$MS" "$T/record-file-other-pr"; VKEY=""
mutation_verdict M26 "was minted for PR #599, not PR #484" \
  "a record signed for another PR at the same head reads as this PR's review — case record-file-other-pr is discriminating"

# M19 — drop the mutually-exclusive snapshot guard (round 8's P3): --write-snapshot is a silent no-op.
MS="$(mutant snapshot-modes 'if [ -n "$SNAPSHOT_IN" ] && [ -n "$SNAPSHOT_OUT" ]; then' 'if [ 0 -eq 1 ]; then')" \
  || bad "M19 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
# this mutation runs a NON-`verify_with` command shape, so its reference (the CORRECT script, same flags,
# round 9 F1) is taken explicitly; the write target differs so the reference cannot create the directory
# the case asserts was never written.
_ref_run --from-snapshot "$T/clean" --write-snapshot "$T/neversnapshot-ref" --repo "$REPO_FIXTURE"
AOUT="$(HOME="$T/home" AI_REVIEW_GATE_KEY="" bash "$MS" --from-snapshot "$T/clean" --write-snapshot "$T/neversnapshot-m" --repo "$REPO_FIXTURE" 2>&1)"; AOUT_RC=$?
mutation_verdict M19 "mutually exclusive" \
  "two mutually exclusive snapshot modes silently no-op — case snapshot-modes is discriminating"

# M20 — drop the comment AUTHOR admission (round 8's BLOCKING finding): any account's marker is evidence.
MS="$(mutant comment-no-author-admission '      if (chan == "COMMENT" && assoc != "OWNER" && assoc != "MEMBER" && assoc != "COLLABORATOR") {' '      if (0) {')" \
  || bad "M20 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
verify_with "$MS" "$T/comment-untrusted-author"
mutation_verdict M20 "its author_association is NONE" \
  "an unattested commenter's marker reads as this PR's review — case comment-untrusted-author is discriminating"

# M21 — drop the comment SIGNATURE requirement where a key resolves (the other half of the same finding).
MS="$(mutant comment-no-sig-required '              if [ -n "$GATE_KEY" ]; then' '              if [ 0 -ne 0 ]; then')" \
  || bad "M21 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
VKEY="$TEST_KEY"; verify_with "$MS" "$T/comment-unsigned-with-key"; VKEY=""
mutation_verdict M21 "its sig= does not verify" \
  "with a key present an unsigned marker comment is admitted — case comment-unsigned-with-key is discriminating"

# M22 — admit a box-local record FILE on trust (the same finding, second channel).
MS="$(mutant record-file-on-trust '      rsha=""; rverdict=""' '      :')" \
  || bad "M22 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
verify_with "$MS" "$T/record-file-unsigned"
mutation_verdict M22 "carries NO sig= field" \
  "an unauthenticated record file reads as evidence — case record-file-unsigned is discriminating"

# M23 — drop the leading-newline strip on the producer frame (`jq -r` writes one after every record):
# a trusted author then reads as "\nOWNER" and the signed, attested marker is refused.
MS="$(mutant frame-no-newline-strip '        sub(/^[\n\r]+/, "")' '        x = 0')" \
  || bad "M23 mutation could not be applied"
[ -n "$MS" ] || MS=/nonexistent-mutant
VKEY="$TEST_KEY"; verify_with "$MS" "$T/comment-signed"; VKEY=""
mutation_verdict M23 "auth=sig" \
  "the producer frame's own trailing newline is not stripped, so a trusted author is refused — case comment-signed is discriminating"

# M27 is only measurable where the producer-side expressions can be EXECUTED (jq + a payload).
if [ -n "${SHIM:-}" ]; then
  # ⛔ M27 — THE EXACT CODE THIS PR SHIPPED, RE-RUN AGAINST A LIVE-SHAPED PAYLOAD: filter kept, endpoint
  # reverted to `pr view`. No snapshot case in this file can see it, because every fixture writes
  # `comments.txt` itself — which is precisely how nine rounds of review passed over an inert channel.
  MS="$(mutant live-fetch-endpoint \
    '"$GH" api "repos/$REPO/issues/$pr/comments?per_page=100" --paginate' \
    '"$GH" pr view "$pr" --repo "$REPO" --json comments')" \
    || bad "M27 mutation could not be applied"
  [ -n "$MS" ] || MS=/nonexistent-mutant
  OUTM="$(SHIM_PAYLOAD="$PAY" AGENT_GH_REAL="$SHIM" HOME="$T/home" AI_REVIEW_GATE_KEY="" \
    bash "$MS" 501 --repo "$REPO_FIXTURE" --write-snapshot "$T/live-m" 2>&1)"; mrc=$?
  REFOUT="$OUTL"; REF_SEEN=1
  AOUT="$OUTM"; AOUT_RC=$mrc
  mutation_verdict M27 "PASS  review_record" \
    "reverting the endpoint to \`pr view --json comments\` makes the comment channel unreadable on a LIVE payload — the live-fetch case is discriminating"
else
  printf '  \033[33mSKIP\033[0m  M27: no `jq` on this box, so the live-fetch read cannot be re-executed\n'
fi

# ── summary ──────────────────────────────────────────────────────────────────────────────────────
printf '\n%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ] || exit 1
exit 0
