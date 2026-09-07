---
title: "Plan: #513 — clean-micro merge verdict: define, tier-bind at mint, pin"
type: engineering
domain: operations
doc_status: live
subjects.team: epistemic-team
created: 2026-09-06
aboutSubjects: epistemic-team
aboutObjects: agent-infra, issue-513, review-enforcer, commit-workflow, record-review, check-pipeline-compliance, issue-485
---

<!-- research-path: decision audited in-repo — scripts/record-review.sh (:86-87 guard slot), extensions/review-enforcer/index.ts (evaluateMergeGate :470-565, logMergeGateDecision :590-607), scripts/check-pipeline-compliance.sh (run_checks check (c)), skills/code-review/SKILL.md Step 10 (:1079-1115), skills/commit-workflow/workflow/03-code-review.md Step 2 + 04-merge-deploy.md condition 6, issue #513 + #485 scoping evidence, ~/.pi/agent/reviews/*.json, ~/.pi/agent/audit/gate-events.jsonl, issue labels via gh -->

# fix(review-enforcer): clean-micro merge verdict is undefined + self-attestable — define who records it, what it certifies, and bind it to the issue tier at record-mint time (Approach A primary + B backstop)

**Goal:** Close the undefined/self-attestable `clean-micro` merge verdict (#513). A `clean-micro` record must certify a DEFINED micro process, be bound to the linked issue's `complexity:micro` label at the moment the record is minted (record-review.sh already calls gh; labels are the tier source), be refused (exit 4, no write) when the linked same-repo issue is NOT micro, be documented in the contract docs (code-review SKILL.md Step 10 / 04-merge-deploy.md condition 6 / 03-code-review.md Step 2), and be pinned with tests (record-review.test.sh label arms + clean zero-extra-call pin; index.test.ts message-shape + audit-verdict + docs-presence pins; check-pipeline-compliance.sh FAIL_ALL seam).

**Team:** epistemic-team
**Issue:** #513 (complexity:standard, Level: project)
**Status:** scoped (issue-scoping v5.1 complete 2026-09-06: problem-verify 2c clean, solution-verify 1c clean, second-model 2c clean, Phase-7 2c clean); implementation pending — plan-review equivalence via fresh-context reviewers at code-review gate

## Decision + Rationale (which approach wins, and why)

### Candidate approaches, re-articulated at full depth

**A. MINT-ENFORCEMENT — record-review.sh tier guard at write time (PRIMARY).**
The record-mint point is `scripts/record-review.sh` (canonical; production copy synced to `~/.pi/agent/scripts/record-review.sh`; the SAME script serves agent-infra and the consumer repos — tortoise/eldato agents run the installed copy and their ai-review-gate workflows consume its marker). The script ALREADY calls gh (stale-sha guard #2133 at :69-86, evidence-post body read + PATCH at :118+), and issue labels are the deterministic tier source (pipeline-compliance reads `complexity:*` labels; pre-flight writes them). A guard slots between the stale-sha guard close (`fi`, :86) and the record write (`DIR=`, :87): when the requested verdict is `clean-micro`, resolve the PR body's same-repo closing-keyword refs (parse_issue_ref semantics) and fetch each ref's labels; (a) `complexity:micro` → allow the record; (b) ANY same-repo closing ref carrying a `complexity:*` label ≠ `complexity:micro` → REFUSE exit 4 with NO write (qualified AND legacy keys untouched — a pre-existing valid record survives, so a failed clean-micro attempt never destroys a valid earlier clean record); (c) no linkage / only cross-repo refs / label fetch failed / fetched labels carry no `complexity:*` / form-shadowed ref / gh missing / repo-less → fail-OPEN with a loud stderr warning (mirrors the stale-sha guard's fail-open posture — a transient gh/API failure must not block a legitimate record — but the warning tells the agent the tier attestation is unverified). Arms (a)/(b) fire ONLY on a successful labels fetch returning a complexity label. `clean` verdicts (standard/complex path) skip the guard entirely → zero extra gh calls (pinned by test). Shared canonical script → consumer repos heal by sync, no per-repo work.

**B. CI-ENFORCEMENT — check-pipeline-compliance.sh check (c) verdict-tier binding (BACKSTOP).**
The repo's deterministic CI gate already runs check (c) (code-review evidence) in the NON-micro branch only (micro b–e exemption untouched). Add verdict-tier binding inside check (c): when the tier is NOT micro and PR_BODY/COMMIT_MSGS claim `verdict=clean-micro` (the record-review.sh marker text `review recorded: reviews/<PR>.json verdict=clean-micro @ <sha> (<repo>)`), FAIL check (c) with guidance to run the code-review skill and re-record `clean` (removing the stale clean-micro marker line — record-review.sh appends, never removes). Runs only in the non-micro branch → the micro exemption is untouched (a legit micro PR with a clean-micro marker still skips b–e). Enforcement timing — HONEST ENVELOPE (Phase-7 DA): with the `edited` trigger (Task 3 step 5), the marker PATCH re-runs the workflow, and a merge attempted AFTER that re-run settles RED is blocked by branch protection. But 80% of observed record→merge gaps are ≤18s — inside the webhook-dispatch race window — so B is an OPPORTUNISTIC backstop that (i) blocks delayed/retried/human merges after a settled red run, and (ii) deters the same-ceremony abuse class; it is NOT a deterministic catch of the fastest first-attempt merge (registered in the Risk Register). B catches the MARKER-BEARING residual subclasses: a forged/incorrect `verdict=clean-micro` marker on a non-micro PR whose body also names that verdict. The workflow supports `workflow_call` — agent-infra's dogfood copy is where B lives; consumer repos (tortoise/eldato) have NO pipeline-compliance workflow, so A is their sole enforcement (B is agent-infra-only). Cost: one branch inside check (c) + FAIL_ALL self-test seams (pass 4: standard tier + clean-micro marker → c fails with binding guidance; pass 5: micro tier + clean-micro marker → 0 failures, pinning that the binding never leaks into the micro exemption) + guidance text (incl. the stale-marker removal step). Out-of-band, deterministic in what it does run, zero LLM.

**C. RECORD-PROVENANCE — additive record fields (attested tier / recorder identity) + honest terminals + drift pins.**
Augment the record JSON (`~/.pi/agent/reviews/<PR>.json`) with fields like the tier attested at mint, and/or add verdict fields to the audit log (merge_gate_pass events), for post-hoc auditability; "honest terminals" = the gate's allow/block messages and audit entries state what actually unlocked the merge. Weakest coercion of the four: the record is plain local JSON written by the agent's own session — forgeable by anyone with FS access (the same agent that wants the merge). An "attested tier" field would be self-attested at mint by the same actor, adding zero independent signal. As a PRIMARY it is theater. Its only honest half is the audit-log verdict field on merge_gate_pass/block entries (post-hoc reconstruction of WHICH verdict unlocked WHICH merge — the exact auditability gap the issue's T1 flagged, given 0/6614 review_dispatch events carry PR identity and the record/marker channels are the only joinable trail). That half is folded into A as a one-field addition to `logMergeGateDecision`, because the record's verdict + repo + reviewed_at + the merge_gate_pass timestamp is the joinable audit trail; the dispatch events are not.

**D. DOCUMENTATION-FIRST — define the contract in prose, minimal code.**
The EASY path with a KNOWN demonstrated non-effect: condition 6 ALREADY names both verdicts and the 7/7 self-certified micro records happened UNDER that documented prose. Prose alone changes no enforcement; the false-cert class (tortoise 3/42: #1702/#2138/#2155 standard/complex recorded clean-micro) survived prose. Acceptable ONLY as the doc component of A (the contract prose IS a deliverable), never alone.

### The decision

**Winner: A as the primary enforcement point, B as an opportunistic (settled-red) CI backstop, C's audit-verdict half folded into A, D absorbed as A's doc component. C's schema addition is rejected (theater over plain-JSON forgeability).**

Evidence, in order of weight:

1. **Merge-time anchoring-dispatch evidence is UNVERIFIABLE — the issue's T1 hypothesis is re-derived as a dead end.** 0/6614 `review_dispatch` audit events carry PR identity (the #485 content-free floor never names a PR), so "require ≥1 review-purpose dispatch whose clean report anchors the record" cannot be checked at merge time in ANY repo the extension gates. The verdict-tier binding at record-mint time IS implementable: record-review.sh already calls gh; issue labels are the tier source (pipeline-compliance reads them deterministically). A binds exactly what can be bound, where the record is created — it does not fake an anchoring-dispatch attestation that the audit trail cannot support. This is the enforcement-honesty axis: bind what is real, name what is unverifiable (arm (c) fail-open warning + contract wording "process certification", NOT "reviewed by N agents").
2. **A refuses the demonstrated false-cert class at mint.** tortoise #1702/#2138/#2155 (standard/complex work recorded clean-micro) → the linked same-repo issue is non-micro → exit 4, no write. The agent-infra 17/17 (all complexity:micro issues, self-written seconds before merge) remain ALLOWED by arm (a) — correctly: those are tier-legit; the fix for that class is (i) the DEFINED contract (clean-micro = process certification: tier verified + pre-flight per risk tier + the #485 ≥1-dispatch floor — all enforced by their own gates that ran earlier in the same session) and (ii) honest messaging. The residual "self-written record" concern is honestly bounded: the record now certifies exactly what earlier enforced gates demonstrably required (a micro session cannot commit at 0 dispatches — #485 uniform block; cannot skip pre-flight; VGATE verifies code sets), and arm (a) attests the tier at mint.
3. **B closes the MARKER-BEARING residuals A cannot reach, at near-zero cost, at the repo's required-check boundary.** A leaves holes: (i) forged/incorrect `verdict=clean-micro` markers on non-micro PRs, (ii) repo-less / gh-less / legacy-script records that ride arm (c) fail-open (these post NO marker — the evidence post requires gh + a resolvable repo, record-review.sh :112 — so B cannot see them; ACCEPTED residual), (iii) hand-minted record JSON that also carries a forged clean-micro marker. B's verdict binding in check (c) catches the marker-bearing subclasses (i) and (iii) — because the ONLY legitimate `verdict=clean-micro` marker on a non-micro PR is a lie. Timing envelope (Phase-7 DA): OPPORTUNISTIC, not deterministic — with `edited` (Task 3 step 5) a merge attempted after the re-run settles red is blocked, but 80% of observed record→merge gaps are ≤18s (inside the webhook race), so same-ceremony first-attempt merges can beat the re-run; B deters and catches delayed/retried merges. B is agent-infra-only (consumer repos have no pipeline-compliance workflow — A is their sole enforcement). Cost is one branch + trigger types + self-test seams + guidance in an existing script with an existing self-test harness.
4. **C's schema addition is rejected; its honest half is absorbed.** Record JSON fields would be self-attested by the same actor (no independent signal) and would touch a format consumed by consumer-repo ai-review-gate markers/parsers — risk without coercion. The audit-log verdict field on merge_gate_pass/block (one line + one test) gives the post-hoc join the scoping flagged: `merge_gate_pass {pr, verdict, reason?}` + the record's reviewed_at reconstructs "which verdict unlocked which merge, when" — the only joinable trail given the dispatch events are unjoinable.
5. **Sequencing/ownership is clean.** A lives in the shared canonical script (heals consumers via sync — tortoise/eldato run the installed copy), B lives in the gate agent-infra owns (the workflow fetches/runs THIS repo's script; workflow_call consumers inherit), D's prose lands in the three contract docs. No schema/marker-text changes → consumer ai-review-gate regex contracts untouched (the marker text and record format are UNCHANGED by this plan).
6. **Rejected alternatives on merit, not diff size.** "CI-only" (B alone) fails as primary: it cannot stop a clean-micro record from being MINTED for a non-micro issue (the record exists, self-attested, on disk and in the audit trail as a pass until CI catches the marker), and it cannot refuse at the only point where the tier is checkable against the actor's own claim. "Docs-only" (D alone) is the known non-effect. "Provenance" (C alone) enforces nothing.

### What each arm does NOT claim (honesty boundary, written into the contract)

- Arm (a) does NOT re-review the diff; it attests the tier. The process claims (pre-flight, dispatch floor) are enforced by earlier gates and stated by the contract — not re-verified at mint.
- Arm (c) fail-open does NOT attest the tier; its warning says so. B is the CI backstop for that class.
- `clean` is NEVER refused for a micro issue (a micro session that actually ran the code-review skill and records clean is a stronger claim, not a false one). The guard fires only on `clean-micro`.
- MIRROR RESIDUAL (second-model P2; living tracker: open issue #566): the guard binds `clean-micro`→micro only; the mirror direction — a standard/complex PR self-recording `clean` without running the code-review skill — is UNCHANGED and tracked under #485 F2 (deliberately content-free floor; out of #513 scope). #513 closes the clean-micro channel; the clean channel remains the accepted org residual with a living owner (#566).
- NON-GOAL (second-model P2): existing false certifications already on disk (tortoise #1702/#2138/#2155) are NOT retroactively purged — they are historical records (already merged); the guard is mint-forward only.

## Implementation Plan

### Task 1 — record-review.sh: clean-micro tier guard (Approach A primary)

**Intent:** Make `clean-micro` mints tier-verified at write time. Guard slots between the stale-sha guard's closing `fi` (:86) and `DIR="$HOME/.pi/agent/reviews"` (:87). Fires ONLY when `VERDICT=clean-micro`; `clean` flows skip it entirely.
**Acceptance:** (a) `complexity:micro` linked issue → record writes (arm a); (b) ANY same-repo closing ref with a `complexity:*` label ≠ `complexity:micro` → exit 4 (distinct from verdict-input 2 and stale-sha 3), NO write, qualified + legacy keys untouched, a pre-existing valid record at the target key survives byte-identical; (c) repo-less / gh missing / no closing ref / only cross-repo refs / labels fetch failed / fetched labels have no `complexity:*` / form-shadowed ref → loud stderr warning + record proceeds (exit 0). Clean flows make ZERO additional gh calls (verified by Task 2's STUB_LOG assertion — no `labels` query on a `clean` run). Record format, marker text, and evidence-post behavior UNCHANGED.
**Files:**
- Modify: scripts/record-review.sh

Steps:
0. **Main-guard refactor FIRST** (Phase-7 codebase-review P2-3): wrap the executable record flow in a main guard (`if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then …record flow…; fi`) so `closing_issue_refs` is defined top-level and SOURCE-reachable by the Task 2 parser-parity test; move the arg-scan/`set --`/`${1:?…}` block inside the guard (sourcing must not abort). The 15 baseline checks protect the refactor (behavior-preserving; run them after). Mandate the main-guard option — do NOT extract a helper file (preserves the 9-file diff contract).
1. Add `closing_issue_refs <text>` — mirrors check-pipeline-compliance.sh `parse_issue_ref` semantics (same 3 forms — full URL `https://github.com/o/r/issues/N`, `owner/repo#N`, bare `#N` → `$REPO` — each requiring the closing keyword `fix(es|ed)?|close(s|d)?|resolve(s|d)?` DIRECTLY followed by the ref; pull-URLs excluded; the SLACK_APPROVAL_FILE shadow class excluded) but returns ALL refs, one `repo#num` per line, instead of first-ref-only. Form priority per ref follows parse_issue_ref. Rationale: the refusal arm needs ANY-ref semantics (a PR closing two same-repo issues of different tiers has no single tier identity → refuse); the micro-allow arm needs ≥1 micro ref with zero refusals. Same-repo = resolved repo equals `$REPO`; cross-repo refs never bind tier (documented: the merge-registry record is minted for THIS repo's PR; the tier contract is same-repo).
2. Insert the guard between the stale-sha guard `fi` (:86) and the `DIR=` line (:87). Structure: `if [ "$VERDICT" = "clean-micro" ]; then` → repo/gh presence check (else arm (c) warning) → `gh api "repos/$REPO/pulls/$PR" --jq .body` (fetch failure → arm (c)) → collect same-repo refs (none → arm (c)) → per ref `gh api "repos/$REPO/issues/<n>/labels" --jq '.[].name'` (fetch failure marks that ref undeterminable — do NOT refuse on a failed fetch, mirroring stale-sha fail-open) → if ANY ref's fetched labels contain `complexity:*` ≠ `complexity:micro` → REFUSE: loud stderr naming the ref + the offending label + exit 4, BEFORE any write or legacy-migration `rm`. Else if ≥1 same-repo ref fetched `complexity:micro` and none refused → allow. Else (no ref yielded any `complexity:*` label — every fetch failed or labels lack complexity) → arm (c) loud warning + proceed. FETCH MECHANICS under `set -euo pipefail` (Phase-7 codebase-review P3-1): a bare failing `gh api` command substitution aborts the whole script — every fetch MUST be `if`-guarded or `$(… 2>/dev/null || true)` with rc-or-content detection exactly mirroring the stale-sha guard's fetch (:73-76, where gh prints 4xx error bodies to stdout and only a well-formed 40-hex sha counts as success).
3. Do NOT touch the evidence-post block, marker text, or record format. Do not reorder the stale-sha guard (Task 2 test 6 pins its log line).
4. Keep the guard's stdout quiet; all guard output to stderr (the evidence-post contract prints one stdout line per record).
5. **Exit-4 REFUSAL MESSAGE must prescribe the compliant act** (Phase-7 DA P1, mirroring MICRO_BLOCK_MESSAGE): name the offending ref + label AND the two remedies — "run the code-review skill on the current head and re-record clean: record-review.sh <PR> <head-sha> clean <repo>" for the standard/complex case, and "if the issue's tier is wrong, relabel it complexity:micro (issue-creation) then re-record" for the mislabel case. Task 2's arm-(b) checks assert these remedy substrings in the exit-4 stderr, not just the exit code.

### Task 2 — record-review.test.sh: verdict-parameterized runner + label arms + clean zero-call pin

**Intent:** Pin the guard behaviorally (red on current HEAD: with no guard, a `clean-micro` record writes regardless of the linked issue's label → the exit-4/no-write/arms assertions fail).
**Acceptance:** suite green; coverage = (a) allow on `complexity:micro`; (b) refuse exit 4 on `complexity:standard`/`complexity:complex` — no write, pre-existing valid record survives, no legacy deletion; (c) fail-open matrix: no complexity label / labels fetch failure (stub exits 1) / body without closing ref / body with only a cross-repo ref / repo-less invocation / gh missing from PATH → exit 0 + record written + warning on stderr; multi-ref any-non-micro refuses while multi-ref all-micro allows; `clean` verdict → STUB_LOG contains the head query + body read + PATCH but NO `labels` query (zero-extra-call pin); parser-parity corpus (the check-pipeline-compliance SELF_TEST vectors asserted against `closing_issue_refs` output through a test-only extraction seam).
**Files:**
- Modify: scripts/record-review.test.sh

Steps:
1. Parameterize the runner by verdict (`run_record_verdict <verdict> <repo-or-empty> <pr> [sha]`); existing `run_record*` helpers delegate with `clean` so the 15 baseline checks stay green.
2. Extend the gh stub: branch on `/labels` (emit `STUB_LABELS` env or per-issue `$STUB_LABELS_FILE` map, log to GH_STUB_LOG), branch on `--jq .body` (emit `{"body": "$STUB_BODY"}`; default `PR body` preserved for the baseline tests — note the DEFAULT body has no closing ref → any baseline `clean` run is unaffected because the guard never fires on `clean`), keep the PATCH and `--jq .head.sha` branches.
3. New checks (STUB_BODY must carry a closing ref, e.g. `Fixes #424300`): arm (a) allow; arm (b) exit-4 matrix over `complexity:standard` / `complexity:complex` incl. no-write + pre-existing-record-survives + no legacy rm; arm (c) matrix above; multi-ref all-micro allow / mixed refuse; clean zero-extra-call STUB_LOG assertion; cross-repo-only body → arm (c).
4. Parser-parity: assert the record-review ref parser agrees with check-pipeline-compliance's parse_issue_ref corpus (the SELF_TEST vectors incl. bare/owner-repo/URL/pull-URL-exclusion/case/shadow/multi-ref-first + the narrative/prose-verb class "This fixes #42 in passing" + the keyword-adjacent prose class) — mirrored vectors in both suites act as the cross-script semantic tripwire. MECHANISM: Task 1 step 0's main guard (already mandated — `[[ "${BASH_SOURCE[0]}" == "$0" ]]` around the record flow, behavior-preserving, protected by the 15 baseline checks) makes `closing_issue_refs` source-reachable — the parity test sources the guarded script and calls the top-level function; NO helper file (preserves the 9-file diff contract). Multi-ref inputs yield DIFFERENT expected outputs per script BY DESIGN (check-pipeline = first-ref; record-review = all-refs) — the parity corpus asserts each script's own semantics, with the mixed-tier-refuse / all-micro-allow matrix as the real tripwire. The parity test must bind BOTH `$REPO` (record-review's same-repo resolution) and `$GH_REPO` (check-pipeline's) — bare `#N` resolves against each script's own repo variable.
5. Red→green demonstration (dev box, documented in the PR): run the new checks against current HEAD (guard absent) → arm (b) exit-4/no-write checks RED (record writes, exit 0); restore the Task 1 guard → GREEN. (Full `git stash` of Task 1 breaks nothing here — bash tests need no module load — but the partial-revert demo isolates the guard.)

### Task 3 — check-pipeline-compliance.sh: check (c) verdict-tier binding (Approach B backstop)

**Intent:** Settled-red CI backstop for the MARKER-BEARING residual classes B can reach (blocks delayed/retried/human merges after an edited re-run settles red; deters the same-ceremony abuse class — fast first-attempt merges inside the webhook-dispatch race are NOT deterministically caught; race registered in the Risk Register): a non-micro PR whose body/commits claim `verdict=clean-micro` fails check (c) with remediation guidance. (A repo-less/gh-less mint posts NO marker — the evidence post requires gh + a resolvable repo — so it is outside B's reach; accepted residual in the Risk Register.)
**Acceptance:** in run_checks, inside the non-micro branch's check (c): when the evidence regex passes BUT the marker text (`PR_BODY` + `COMMIT_MSGS`) contains `verdict=clean-micro`, check (c) FAILS naming the binding and the remedy (run the code-review skill, record `clean`). Micro branch untouched (b–e skip as today — the binding never leaks into the micro exemption). `PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 PR_NUMBER=1` runs 5 simulation passes (existing 1–3 renumbered + pass 4 standard-with-clean-micro-marker asserting c's binding failure + pass 5 micro-with-clean-micro-marker asserting 0 failures; pass headers renumbered "pass N of 5") and the SELF_TEST corpus stays green. NOTE: the script's top guard requires PR_NUMBER unless SELF_TEST=1 — FAIL_ALL invocations MUST set PR_NUMBER=1 (without it the script exits 2 on the usage guard before any pass runs). TRIGGER PRECONDITION (second-model P1): the dogfood workflow's pull_request trigger MUST gain `types: [opened, synchronize, reopened, edited]` — record-review.sh PATCHes the marker into the PR body at record time (an `edited` activity) after the last push; without `edited` the default types never re-run the gate post-marker and the binding cannot fire at merge.
**Files:**
- Modify: scripts/check-pipeline-compliance.sh
- Modify: .github/workflows/pipeline-compliance.yml (dogfood copy only — add the `types:` list per step 5; NOT materialized by sync-ci-workflows.sh — the workflow-drift job's 3-file diff list is python-ci/node-ci/docs-ci — so edit in place; the templates/ copy keeps its generic consumer trigger)

Steps:
1. In run_checks check (c) (non-micro branch only): compute the marker-text variable once; when the evidence grep matches, additionally test `verdict=clean-micro` against the same marker text; if present → `fail c` with "clean-micro verdict marker on a NON-micro linked issue (tier <tier>) — clean-micro certifies the micro process only; run the code-review skill on the current head and re-record clean: record-review.sh <PR> <head-sha> clean <repo>" and skip the pass line. STALE-MARKER REMEDY (second-model P2): record-review.sh APPENDS markers and never removes them — after re-recording `clean`, the old `verdict=clean-micro` line remains in the body and the binding still fires. The failure guidance MUST also instruct removing the stale marker line from the PR body (the agent edits the body to delete the `review recorded: … verdict=clean-micro …` line, or rewrites the body); without that the remedy loops.
2. FAIL_ALL pass 4 (after pass 3): `PR_BODY="Fixes #1" + the literal marker line "review recorded: reviews/1.json verdict=clean-micro @ <40hex> (repo)"`, `LABELS="complexity:standard"`, `COMMIT_MSGS=""`, `FILES` = runtime code → assert check (c) fails AND its failure text names the verdict binding.
3. FAIL_ALL pass 5 (micro exemption pin): `LABELS="complexity:micro"`, body = "Fixes #1" + the same clean-micro marker, `COMMIT_MSGS=""`, docs-only `FILES` → `FAILURES=0` (a passes, b–e skipped; the binding must NOT leak into the micro exemption).
4. Red→green: pass 4 RED on current HEAD (check (c) passes the generic evidence grep on the marker → no binding failure). Pass 5 (micro + clean-micro marker → 0 failures) is green pre- AND post-change BY DESIGN — it is a placement-leak guard (red only if the binding leaks outside the micro exemption), NOT evidence the binding exists; the red→green proof rests on pass 4 alone.
5. Add `types: [opened, synchronize, reopened, edited]` under the pull_request trigger in .github/workflows/pipeline-compliance.yml with a #513 comment naming the edited-event dependency (the marker PATCH is an `edited` activity fired after the last push).

### Task 4 — review-enforcer index.ts: remediation-message honesty + audit verdict field

**Intent:** Every gate terminal that names a record or a remedy must state the truth for BOTH tiers and interpolate the actual recorded verdict where a record exists. The gate has NO tier read — where no record exists it emits two-path static text; where a record exists it interpolates `record.verdict`. Verdict membership `clean|clean-micro` is UNCHANGED at the two decision sites.
**Acceptance:** no `record-review.sh … clean [owner/repo]` remediation remains hardcoded where a record exists (all interpolate `record.verdict`); no-record arms carry the two-path remediation; the allow message interpolates `record.verdict` instead of the hardcoded "(clean review…)"; `evaluateMergeGate` verdict membership (:503) and `mergeGateBlockReason` (:588) are byte-unchanged; `logMergeGateDecision` pass AND block audit entries carry the record verdict when a record exists.
**Files:**
- Modify: extensions/review-enforcer/index.ts

Steps:
1. **No-record arms (task sub-agent :483-490, interactive :491-497)** — replace the single "run the code-review skill … record clean" remediation with two-path static text (no tier read — the gate has none):
   - task-sub-agent shape keeps "The parent session must record the review:" + the #285 line "does NOT unlock sub-agent merges (#285)"; no "Emergency:" line (existing pins hold).
   - interactive shape keeps the escape-hatch line (existing pin holds).
   Two-path body (both shapes):
   ```
   "   →   Micro issue (complexity:micro): complete the micro flow (pre-flight + a review dispatch naming the diff), then"
   "   →     record-review.sh <PR> <head_sha> clean-micro [owner/repo]"
   "   →   Standard/complex issue: run the code-review skill, then"
   "   →     record-review.sh <PR> <head_sha> clean [owner/repo]"
   ```
2. **Verdict-not-clean arm (:503-511)** — failure line keeps interpolating the actual `record.verdict`; remediation becomes the same two-path text (the record's tier is not readable from the record — only the verdict — so the two-path remediation is the honest form; the issue label is the tier source and the agent can read it).
3. **Head-unverifiable arm advices (:538/:540 interactive, :527 sub-agent)** — record EXISTS in this arm, so interpolate: re-record at the SAME verdict the record already holds (`record-review.sh <PR> <head_sha> ${record.verdict} owner/repo`) — re-recording `clean` over a clean-micro record would FALSELY certify multi-agent code review at micro; re-recording clean-micro over a clean record would downgrade a real review. Sub-agent :527 shape: parent records — interpolate `record.verdict` too.
4. **Head-advanced arm (:555)** — record exists: "re-review the new head and re-record at the same verdict (<record.verdict>): record-review.sh <PR> <head_sha> <record.verdict> [owner/repo]".
5. **Allow message (:561-563)** — interpolate: `(… (${record.verdict} review, head ${…} matches) — allowing merge` (renders "(clean review…)" or "(clean-micro review…)" from the record, never a hardcode).
6. **`logMergeGateDecision` (:590-607)** — pass and block entries gain `verdict: record?.verdict` when a record exists (post-hoc join: which verdict unlocked which merge — the honest-terminal half of approach C). Fail-open keeps its `reason: "failopen"` marker.
7. Do NOT touch: verdict membership (:503, :588), `mergeGateBlockReason`, the #285 fail-closed head-null sub-agent branch structure, MICRO_BLOCK_MESSAGE/BLOCK_MESSAGE dispatch-gate messages (out of scope — commit-time, #485-owned).

### Task 5 — index.test.ts: message-shape pins + audit-verdict assert + docs-presence pins

**Intent:** Pin Task 4's message honesty and the audit field so a regression to a hardcoded "(clean review…)" or a single-path remediation fails CI; pin the contract-doc prose (Task 6) so it cannot silently re-drift (mirrors the #485 T2/T3 pattern at presence-pin depth — no new machine-read fence table needed; the clean-micro contract is prose, so the pins assert required sentences exist, vacuous-pass-guarded).
**Acceptance:** suite green; new tests mirror the #285 shape-aware section's assert style (includes/absence on the returned reason strings).
**Files:**
- Modify: extensions/review-enforcer/index.test.ts

Steps:
1. **No-record two-path pins** (extend the #285 section tests or add a #513 section): task-sub-agent no-record reason includes BOTH bracket-disambiguated invocation forms — `record-review.sh <PR> <head_sha> clean-micro [owner/repo]` AND `record-review.sh <PR> <head_sha> clean [owner/repo]` — keeps "does NOT unlock sub-agent merges (#285)", has no "Emergency:" line; interactive no-record reason includes both disambiguated forms AND "Emergency: set AGENT_SKIP_REVIEW_GATE". ⚠️ The clean-side include MUST use the bracket-disambiguated form `…head_sha> clean [owner/repo]` (never the bare `…> clean` prefix) — a bare form is satisfied by the clean-micro line (substring truncation at "clean" before "-micro") and would pass green while the standard/complex path is missing.
2. **Verdict-not-clean pin**: record verdict `"fail"` → reason includes both disambiguated remediation forms and the failure line interpolates `"fail"`.
3. **Head-advanced interpolation pins** (discriminating substrings — `"head_sha> clean-micro [owner/repo]"` vs `"head_sha> clean [owner/repo]"` never collide): clean-micro record + advanced head → block reason contains the clean-micro record-review invocation and NOT the clean one; clean record + advanced head → the reverse.
4. **Allow-message interpolation pins**: clean-micro record + matching head → allow message contains `"(clean-micro review, head"`; clean record → `"(clean review, head"` (neither substring is a prefix of the other, so the asserts discriminate).
5. **Audit-verdict assert**: withTempHome + a written clean-micro record + matching-head merge → the temp `gate-events.jsonl` merge_gate_pass entry carries `verdict: "clean-micro"`; block path carries the verdict too.
6. **Docs-presence pins (#513)** — source-checkout-guarded (isSourceCheckout soft-skip + vacuous-pass guards, mirroring #485 T2): resolve `skills/code-review/SKILL.md`, `skills/commit-workflow/workflow/04-merge-deploy.md`, `skills/commit-workflow/workflow/03-code-review.md` via `new URL(..., import.meta.url)`; assert distinctive tokens exist (scan case-INSENSITIVE, mirroring the T2 convention — the appendix prose renders REFUSES uppercase). TIER tokens: SKILL.md Step 10a region (anchored between `### Step 10a` and `## Standard-Tier Review`) contains "clean-micro" + "complexity:micro" + "exit 4"; 04-merge-deploy.md condition-6 region (bounded between the condition-6 header `6. **Review record at the final head` and the `**Human escalation (only for):**` heading — condition 6 is the LAST numbered condition, there is no "condition 7") contains "clean-micro" (NOTE: 04 already contains clean-micro once pre-change — the discriminating reds are the other two tokens) + "03-code-review.md Step 2" + "refuses"; 03-code-review.md micro paragraph contains "clean-micro" + "record-review.sh". NEGATION tokens (the operative #513 definitional claim — an editor could delete "NOT multi-agent / never at micro" while the tier tokens survive): SKILL.md Step 10a region additionally contains "NOT multi-agent" or "never recorded at micro"; 03 micro paragraph contains "not a multi-agent" (per Block C wording). (Pre-change red is real: today SKILL.md has zero clean-micro/complexity:micro/exit-4 occurrences, 03's micro paragraph has zero clean-micro/record-review.sh occurrences, and no doc contains the negation tokens.)
7. Red→green demonstration: author 1/3/4/5 against current HEAD → RED (hardcoded messages); apply Task 4 → GREEN. Presence pins are RED before Task 6 doc edits.

### Task 6 — contract docs: define clean-micro (who records it, what it certifies, when)

**Intent:** The prose deliverable — drop-in wording below. Code-review SKILL.md Step 10 gains the Micro-tier recording subsection (clean-micro = PROCESS certification; recorder = the micro flow; the code-review skill is NEVER the micro recorder because micro skips it); 04-merge-deploy.md condition 6 names the micro recording path (currently dead prose names only the code-review skill); 03-code-review.md Step 2 micro paragraph gains the recording pointer while staying #485-T2 anti-token-clean.
**Files:**
- Modify: skills/code-review/SKILL.md (Step 10 → add Step 10a subsection after the existing bullets, before `## Standard-Tier Review`)
- Modify: skills/commit-workflow/workflow/04-merge-deploy.md (condition 6 paragraph)
- Modify: skills/commit-workflow/workflow/03-code-review.md (Step 2 micro paragraph terminal sentence)

Drop-in prose is specified in the appendix of this plan (verbatim blocks A/B/C). Do not reword; the Task 5 presence pins assert specific sentences.

### Task 7 — plan doc, pre-flight, ceremonies, merge, canonical mirror sync

**Intent:** Land the unit (2 scripts + 2 test files + 1 extension + 3 docs + this plan) through the full commit ceremony; post-merge, sync the canonical record-review.sh mirror so running agents execute the guarded copy.
**Acceptance:** PR opened with body "Fixes #513"; code-review to convergence; merged; issue labeled implemented; `diff scripts/record-review.sh ~/.pi/agent/scripts/record-review.sh` reports identical post-sync.
**Files:**
- Create: docs/plans/2026-09-06-issue-513-clean-micro-verdict.md (this doc)

Steps:
1. Pre-flight per 01-preflight (mixed code+docs set: record-review.sh + check-pipeline-compliance.sh bash syntax, extension suite, docs pins) + skill enforcement audit.
2. Test-Review ceremony on the two modified test files (test-writing → test-review). Note the #485-documented pre-flight hash-gate body-grep quirk applies if this plan doc's prose contains the literal `complexity:micro` (it does) — the hash gate may silently skip; the ceremony still runs because test-writing mandates independent review of edited test files.
3. Open the PR (draft), code-review to convergence (second-model final gate), record `clean`, merge.
4. **Post-merge canonical mirror sync (manual — automation tracked in #562, do NOT absorb):** `cp scripts/record-review.sh ~/.pi/agent/scripts/record-review.sh` and verify `diff` is empty. Consumer repos (tortoise/eldato) inherit the guarded script via their next canonical-copy sync — A is their SOLE clean-micro enforcement (they have no pipeline-compliance workflow; B is agent-infra-only).
5. **Extension mirror sync (Task 4's consumer reach):** extensions/review-enforcer/index.ts changes (message honesty + audit verdict field) reach consumer sessions via the installed extension mirror (~/.pi/agent/extensions/review-enforcer) — verify it converges on the next pi-bootstrap/setup sync (or sync explicitly) and `diff` the installed copy against the repo copy. The clean-channel residual has a living tracker: issue #566 (filed during Phase 7 — do not absorb).

## Integration Surface Map

| Surface Type | Specific Surface | Data Flow | Contract | Test Layer |
|---|---|---|---|---|
| Record minting | scripts/record-review.sh guard (between stale-sha guard :86 and write :87) | in/out | clean-micro → tier-verified via linked issue labels; exit 4 on ANY same-repo non-micro ref; fail-open loud otherwise; clean → zero extra gh calls | record-review.test.sh (stub labels/body, STUB_LOG) |
| GitHub labels (tier source) | gh api repos/$REPO/issues/<n>/labels | in | complexity:* label space (micro allow / other refuse / absent fail-open) | record-review.test.sh stub |
| Issue linkage parse | PR body closing keywords (URL / owner/repo#N / bare #N; keyword-directly-followed) | in | mirrors check-pipeline-compliance parse_issue_ref semantics; ALL-refs for refusal; same-repo only | mirrored corpus in record-review.test.sh + existing pipeline SELF_TEST |
| Merge registry gate | index.ts evaluateMergeGate verdict membership (:503, :588) | internal | clean \| clean-micro UNCHANGED | existing suite (99 green baseline) |
| Gate terminals | index.ts remediation + allow messages | internal | record exists → interpolate record.verdict; none → two-path static; no hardcoded clean-only remediation | index.test.ts message pins (#285-style) |
| Audit trail | index.ts logMergeGateDecision | in | pass/block entries carry record verdict | index.test.ts audit-verdict assert |
| CI gate (backstop) | check-pipeline-compliance.sh check (c) | in | non-micro + verdict=clean-micro marker → FAIL with guidance; micro exemption untouched; OPPORTUNISTIC envelope (settled-red-run blocks delayed merges; same-ceremony first-attempt race accepted) | FAIL_ALL passes 4 + 5 + SELF_TEST |
| Contract docs | SKILL.md Step 10a, 04 condition 6, 03 Step 2 | bidirectional | clean-micro = process certification prose | index.test.ts docs-presence pins |
| Consumer repos | tortoise/eldato ai-review-gate (marker regex + record file); NO pipeline-compliance workflow there | in | record format + marker text UNCHANGED; A (record-review.sh guard) inherited via canonical-script sync = their SOLE clean-micro enforcement; B is agent-infra-only | post-merge manual verify (no consumer code change) |
| Canonical mirror | ~/.pi/agent/scripts/record-review.sh | out | sync post-merge (#562 automation pending) | manual diff |

## Verification Plan

- `NODE_ENV=test npx tsx extensions/review-enforcer/index.test.ts` → baseline 99 passed, 0 failed (locked 2026-09-06 on worktree HEAD); after Tasks 4/5/6 → all green (new message/audit/presence tests included).
- `bash scripts/record-review.test.sh` → baseline PASS=15 FAIL=0; after Tasks 1/2 → all green (label arms, fail-open matrix, multi-ref, clean zero-extra-call, parser corpus).
- `bash -n scripts/record-review.sh scripts/check-pipeline-compliance.sh` → clean.
- `PIPELINE_COMPLIANCE_SELF_TEST=1 bash scripts/check-pipeline-compliance.sh` → SELF-TEST PASS (vectors unchanged).
- `PIPELINE_COMPLIANCE_DRY_RUN=1 PIPELINE_COMPLIANCE_FAIL_ALL=1 PR_NUMBER=1 GH_REPO=daniel-ospina/agent-infra bash scripts/check-pipeline-compliance.sh` → all 5 simulation passes printed (exit 1 by design — the simulation's terminal status; each pass's assert lines green, incl. pass 4 binding-failure + pass 5 micro-exemption-zero-failures).
- Workflow-drift CI stays green (pipeline-compliance.yml is not in the drift job's 3-file list; no symlink introduced).
- TRIGGER-EDIT assertion: `.github/workflows/pipeline-compliance.yml` pull_request trigger contains `types:` including `edited` (grep-verify post-edit — this exact property was the second-model P1).
- Red→green demonstrations (dev box, documented in PR): (1) record-review.test.sh arm (b) checks RED against HEAD pre-Task-1 (no guard → clean-micro writes for a standard-linked issue); (2) check-pipeline FAIL_ALL pass 4 RED pre-Task-3; (3) index.test.ts message pins RED pre-Task-4, presence pins RED pre-Task-6.
- `git diff --stat` → exactly the 9 files (record-review.sh, record-review.test.sh, check-pipeline-compliance.sh, .github/workflows/pipeline-compliance.yml, index.ts, index.test.ts, SKILL.md, 04-merge-deploy.md, 03-code-review.md) + this plan doc. No changes to: review-record JSON schema, marker text, record-review.sh evidence-post block, 01/02 preflight-commit docs, verification-gate, MICRO_BLOCK_MESSAGE/BLOCK_MESSAGE, templates/ copy, consumer repos.
- Code-review (commit-workflow Step 2/3) with fresh reviewers; second-model final gate; post-merge mirror sync diff.

### Test-Review Cycle Log (to be filled during execution)

| Cycle | Reviewers | Verdict | Issues fixed |
|---|---|---|---|
| — | not yet run | — | — |

## Risk Register

| Risk | Mitigation |
|---|---|
| parse_issue_ref semantics duplicated into record-review.sh drifts from check-pipeline-compliance.sh | Shared vector corpus asserted in BOTH self-tests (Task 2 step 4) = cross-script semantic tripwire; guard refusal keys on the deterministic same-repo subset only; refusal arms documented (ANY-ref for refusal, ≥1-micro for allow, form priority per parse_issue_ref) |
| Multi-ref PR bodies (mixed tiers) newly refused | Fail-closed by design — a PR closing a micro AND a standard issue has no single tier; contract docs tell agents not to use closing keywords for refs they do not close ("Related:" prose instead) |
| Arm (c) fail-open class (repo-less / gh-less / no-linkage / no-complexity-label mints remain unverified at mint; they post NO marker so B cannot see them) | Loud stderr warning names the gap; ACCEPTED residual — low likelihood (the merge ceremony runs in-repo so repo auto-detects; the #426 repo-qualified key era means repo-less clean-micro records are legacy/anomalous) and capability equals pre-existing prose-evidence forgeability |
| Label-mutation attack (issue #379 template: relabeled standard→micro 87s before a self-certified clean-micro record; defeats A and B simultaneously and downgrades CI to the micro b–e exemption) | ACCEPTED residual — arm (a) attests a label the recording actor can mutate; it is an accident-guard, not an attestation. Tripwire option (B firing when the complexity label changed after the PR opened) is a possible future hardening — NOT in this PR. The honest-label population (all observed tortoise false certs carried honest non-micro labels) is what arm (b) refuses |
| B timing race (80% of record→merge gaps ≤18s < edited-re-run dispatch window; no concurrency group; every body edit re-runs the gate) | ACCEPTED — B restated as opportunistic backstop (blocks delayed/retried/human merges after a settled red run; deters the same-ceremony class). Mitigations: the ceremony's own gh pr merge retry loop + the review-enforcer no-record/verdict block mean most abuse attempts eventually hit a red run |
| Clean-channel residual (standard/complex self-recording `clean` without the code-review skill; hand-mints carrying forged clean markers invisible to B) | FILED as open issue #566 (2026-09-06) — a living tracker replacing the #485-F2 circular reference. #513 closes the clean-micro channel only; the clean channel is the accepted org content-free-floor residual with an owner |
| 17/17 agent-infra clean-micro records stay allowed (arm a) | Intended — they are tier-legit; the contract + pre-existing enforced gates (pre-flight, #485 ≥1-dispatch, VGATE) carry the process claims; arm (a) attests tier, not review |
| Hardcoded single-path remediation re-drifts in the gate | Task 5 message pins (discriminating substrings) fail CI on the regression |
| Clean flows gain accidental gh calls | Task 2 STUB_LOG assertion: no `labels` query on a `clean` run |
| Consumer ai-review-gate breakage | Record JSON schema + marker text + evidence-post block UNTOUCHED; only the refusal arm (pre-write) and check (c) branch change; consumers (tortoise/eldato) inherit the guarded script via canonical-copy sync — their ai-review-gate regex (verdict=clean(-micro)?) is unchanged; B does not reach them (no pipeline-compliance workflow there) |
| Canonical mirror lag (~/.pi/agent/scripts/record-review.sh stale until Task 7 sync; automation #562 pending) | Explicit post-merge sync step + diff verification in Task 7; until then the installed copy is the pre-guard script (agents on consumer repos unaffected — the guard is additive) |
| Line anchors drift (origin/main advances post-draft) | Edit content-first (unique text, not line numbers) per #485 precedent; re-verify the :86/:87 slot and the index.ts anchor strings before editing |
| Worktree npm state (extension node_modules was broken locally; npm ci needed) | Local-only fix, gitignored; CI runs its own `npm ci` per extension (ci-main.yml :80) |
| Presence pins pass vacuously (doc path moves) | isSourceCheckout + existsSync vacuous-pass guards mirroring #485 T2 |
| check (c) binding false-fires on historical commit text claiming clean-micro on a non-micro PR | Markers are posted to PR BODIES by record-review.sh, not commit messages; a commit claiming verdict=clean-micro on a standard/complex PR is itself a false claim — fail-closed with guidance is correct |
| Pre-flight hash-gate body-grep quirk (this plan's prose contains `complexity:micro`) | Documented in Task 7 step 2; test-review ceremony runs regardless |

## Learnings

To be appended after execution (per memory contract — no code gotcha expected).

## Appendix — drop-in contract prose (verbatim)

### A. skills/code-review/SKILL.md — add after Step 10's bullets, before `## Standard-Tier Review`

```markdown
### Step 10a — Micro-tier recording: verdict `clean-micro` (#513)

Micro tier SKIPS this skill entirely (commit-workflow `03-code-review.md`
Step 2) — the Step 10 auto-record above NEVER fires at micro, yet the merge
gate demands a review record at EVERY tier (04-merge-deploy.md condition 6).
Micro PRs therefore record the PROCESS verdict `clean-micro` via the micro
flow. Before recording, ALL of these must hold:

1. **The linked issue is `complexity:micro`.** The PR body's closing keyword
   resolves a same-repo issue carrying the `complexity:micro` label at record
   time. `record-review.sh` verifies this itself and REFUSES (exit 4, no
   write) any `clean-micro` record whose linked same-repo issue is NOT micro —
   a standard/complex issue is never recorded `clean-micro`: run THIS skill
   and record `clean` (Step 10).
2. **Pre-flight passed per risk tier** (01-preflight.md: typecheck/tests on
   code-bearing micro sets; Low-risk docs/CSS/static sets exempt).
3. **The #485 ≥1-dispatch floor was met.** Code-bearing micro sets satisfy it
   via VGATE's own `[VGATE]` verification dispatch (naming the diff);
   docs-only sets dispatch a lightweight reviewer naming the diff — a
   one-line "NO ISSUES FOUND" check counts (the floor is deliberately
   content-free).

`clean-micro` certifies the MICRO PROCESS — tier verified against the linked
issue's label, pre-flight per risk tier, the #485 dispatch floor — NOT
multi-agent code review and NOT code quality. Record at the current head only:

**One PR closes one issue.** A closing keyword in the PR body auto-closes
that issue on merge. record-review.sh therefore refuses (exit 4) a
`clean-micro` record whose body closes ANY same-repo issue that is not
`complexity:micro`. If the body references an issue the PR does NOT close,
write `Related: #N` prose instead of a closing keyword — or run THIS skill
and record `clean` for a standard/complex-linked change.

```bash
# ~/.pi/agent/scripts/record-review.sh is not on PATH — use the explicit path.
~/.pi/agent/scripts/record-review.sh <PR_NUMBER> <FULL_HEAD_SHA> clean-micro
```

Recorder = the micro flow (03-code-review.md Step 2). The merge ceremony must
NOT self-certify a fresh record: if the gate blocks, run the review
appropriate to the tier (this skill at standard/complex; the micro flow at
micro), then record.
```

### B. skills/commit-workflow/workflow/04-merge-deploy.md — condition 6 rewrite

Replace the condition-6 paragraph's middle sentences (from "The `code-review`
skill records automatically" through "use the explicit path)") with:

```markdown
   Verdict by tier: **standard/complex** PRs record `clean` — the
   `code-review` skill records automatically on clean convergence (Step 10).
   **Micro-tier PRs** (linked issue `complexity:micro`) record `clean-micro`
   via the micro flow (03-code-review.md Step 2) — the code-review skill is
   SKIPPED at micro, so the micro flow's record is `clean-micro`, and the
   merge ceremony never self-certifies a record. (`clean` is never REFUSED at
   any tier — a micro session that actually ran the code-review skill and
   records `clean` is a stronger claim, not a false one.) One PR closes one issue: a PR
   whose body closing-keyword references a non-closed issue auto-closes it on
   merge — reference non-closed issues as `Related:` prose instead, or the
   refusal (exit 4) will correctly stop the `clean-micro` record. `clean-micro` certifies the micro
   PROCESS: `record-review.sh` verifies the linked same-repo issue's
   `complexity:micro` label at record time and REFUSES (exit 4) a
   `clean-micro` record whose linked issue is not micro; pre-flight per risk
   tier and the #485 ≥1-dispatch floor are enforced by their own gates. If
   the head moved after the record (fix commits, merge of main): re-run the
   review appropriate to the tier (the `code-review` skill at
   standard/complex; the micro flow at micro) on the new head, then re-record
   at the SAME verdict —
   `~/.pi/agent/scripts/record-review.sh <PR> <full-head-sha> clean
   <owner/repo>` (standard/complex) or `… clean-micro <owner/repo>` (micro)
   (the script is not on PATH — use the explicit path).
```

### C. skills/commit-workflow/workflow/03-code-review.md — Step 2 micro paragraph pointer

Replace the micro block's terminal sentence ("Proceed directly to Step 3
(`04-merge-deploy.md`).") with:

```markdown
Before Step 3, record the merge-registry record at the current head
(04-merge-deploy.md condition 6): micro PRs record verdict `clean-micro` via
`~/.pi/agent/scripts/record-review.sh <PR> <head-sha> clean-micro
<owner/repo>` — the script verifies the linked issue's `complexity:micro`
label and REFUSES (exit 4) a clean-micro record whose linked same-repo issue
is not micro. `clean-micro` certifies this micro process (pre-flight + the
≥1-dispatch floor above), NOT a multi-agent review — by the standard micro
flow the record is `clean-micro`, and `clean` is never refused at any tier (a
micro session that ran the code-review skill and records `clean` is a
stronger claim, not a false one). Proceed directly to
Step 3 (`04-merge-deploy.md`).
```

<!-- plan-review: cycles=1, status=clean, version=1.0.0 — reviewed via issue-scoping's Phase-7 reviewer cycle (fresh-context codebase + DA reviewers), re-review clean, second-model coherence cycles clean. Pre-implementation edit log: Task 1 guard refactor, Task 2 check (c) binding + types[edited] hardening, Task 4 two-path remediation messages + audit-verdict field + #285 pins preserved, Task 5 test pins, Task 6 Blocks A/B/C applied verbatim (GREEN, 110/110). -->
