#!/usr/bin/env bash
# selftest.sh — offline checks for the shipped harness. No network, no tmux server, no git writes.
#
# IMPORTANT — how these checks are written.
# Several defects found in review were "the logic looks fixed but nothing calls it". So a check that
# RE-IMPLEMENTS the fixed logic proves nothing: it passes on the broken copy too. Every check below
# therefore EXTRACTS the real code from the shipped script (the classifier, sess(), esc(), the
# claim block, the reaper) or runs the real script, and asserts on its behaviour. Verified the hard
# way: dropping this file into the pre-fix tree fails these checks.
#
#   ./selftest.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
pass=0; fail=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; pass=$((pass+1));
  else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; fail=$((fail+1)); fi
}
LOOP="$HERE/orch-loop.sh"; MERGE="$HERE/merge-one.sh"; INST="$HERE/install.sh"; REFRESH="$HERE/refresh-candidates.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# ⛔ HERMETIC (agent-infra#1901): `OR` is now a VALIDATED INPUT — the queue's repo, derived from the
# fixture checkout's `origin` remote unless declared — so a developer's ambient OR would be held
# against every fixture remote below and turn unrelated cases red (measured: 13 such arms). Cases
# that care about OR set it EXPLICITLY on the command line.
unset OR
# ⛔ AND `HARNESS_FORK_PATHS` (review P2, re-review round): it is an OPERATOR setting that README §11
# tells you to export in the very shell you run `doctor` from. The group below asserts
# `forksChecked is False` for an unconfigured run, so an operator who followed §11 reddened this suite
# (`"forks": "ok", "forksChecked": true` → AssertionError) — a false block in a shard CI runs.
unset HARNESS_FORK_PATHS
# A missing extraction must FAIL, not warn: if the shipped script lacks the code under test the
# dependent checks would pass on an empty file — the exact vacuity this file was rewritten to fix.
need() { if [ -s "$1" ]; then return 0; else ck "$2" 1; return 1; fi; }
# ── PLATFORM GATE (agent-infra#1769 review) ──────────────────────────────────────
# install.sh is macOS-only BY CONSTRUCTION: its preflight is
# `[ "$(uname)" = "Darwin" ] || die "this harness uses launchd + tmux; only macOS is supported"`,
# and every check that drives it to a rendered plist needs `plutil` and launchd. Wiring this suite
# into `scripts/run-bash-shards.sh` (the shard list BOTH CI lanes run on ubuntu-latest) therefore
# reddened `bash-suites` and would redden main's `script-validate` — the #1369 class the shard list
# exists to close. Those checks are SKIPPED LOUDLY off macOS instead of failing: a silently-absent
# suite would be the SAME class again. `skipd` counts and names each skip, and the final summary
# reports the count, so a green Linux run cannot hide a suite that did not run.
PLATFORM="$(uname)"
skip=0
skipd() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; skip=$((skip+1)); }
on_darwin() { [ "${PLATFORM:-}" = "Darwin" ]; }
# OFFLINE: install.sh probes the REAL `gh` (`gh auth status`) and dies without a live authenticated
# session, so the install/render checks below would need network. A `gh` stub that reports success
# is FIRST on PATH for that reason — the header's "no network" contract is then true. Checks that
# need the real resolution build their own PATH explicitly (§17 daemon-PATH, §6c) and are unaffected.
GSTUB="$TMP/stub-bin"; mkdir -p "$GSTUB"
printf '#!/bin/bash\n[ -n "${GH_HOME_RECORD:-}" ] && printf "%%s\\n" "$HOME" >> "$GH_HOME_RECORD"\nexit 0\n' > "$GSTUB/gh"; chmod +x "$GSTUB/gh"
# ⛔ THE SANDBOX LABEL (agent-infra#1996). launchd labels are GLOBAL, so a plist rendered under a
# throwaway $HOME still addresses the PRODUCTION job by name when it carries the production label —
# addressing it writes a PERSISTENT Disabled override for the controller the box is actually running,
# i.e. a "sandboxed" test can silence production. Every install.sh invocation in this file therefore
# installs a TEST label (install.sh refuses a non-default label on a real $HOME), and every sandbox
# plist below is addressed by $TPL, never by the production filename.
PROD_LABEL="com.eldato.orchestrator-loop"
# ⛔ BOTH PRODUCTION LABELS, not just the loop's (review catch, 2026-10-18). Disabling the production
# WATCHDOG writes the same persistent override (PR #1986 ships it), and leaving it unguarded meant the
# stated property ("no test can address production") was wider than the measured one.
PROD_WD_LABEL="com.eldato.orchestrator-watchdog"
TEST_LABEL="$PROD_LABEL-test"
TPL="$TEST_LABEL.plist"
# ⛔ `LABEL_OVERRIDE`, NOT `LABEL` (review catch, 2026-10-18): install.sh assigns the production label
# as a QUOTED LITERAL (scripts/test_pr_doctor.py pins that line), so an exported `LABEL` does not reach
# it — the suite would render the production label into a sandbox $HOME and the label guard would
# (correctly) refuse every install here.
export LABEL_OVERRIDE="$TEST_LABEL"
export PROD_LABEL PROD_WD_LABEL TEST_LABEL TPL

# ⛔ AND A `launchctl` STUB, WHICH REFUSES THE PRODUCTION LABELS. install.sh READS the domain on every
# run and `--uninstall` removes the job; against the REAL launchd, from a sandbox $HOME, that removal
# resolved the PRODUCTION label and booted the live controller out (measured 2026-10-17). The stub is
# first on PATH for the whole suite, records every invocation, and exits 97 when the call NAMES a
# production label — asserted at the end of the run (§6g), so "no test addressed production" is
# MEASURED, not assumed. The pattern excludes the test labels, which carry a `-` suffix
# (`…-loop-test`).
# ⛔ AND FOR EVERYTHING ELSE IT MUST SPEAK launchd's OWN NOT-FOUND LANGUAGE (`Could not find service …`,
# exit != 0), not a bare `exit 1`: `lc_probe` classifies a non-zero read with UNRECOGNISED output as
# UNKNOWN and the caller then refuses, so a silent stub made every `install.sh --uninstall` here fail —
# and the failing check was labelled "blocked by SCOPE=banana", pointing the next lane at config
# validation instead of at the fixture (review finding: a registered shard went red).
LM_LOG="${LM_LOG:-$TMP/launchctl-calls.log}"
export LM_LOG
cat > "$GSTUB/launchctl" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${LM_LOG:-/dev/null}"
if [[ " $* " =~ (^|[^a-z-])com\.eldato\.orchestrator-loop([^a-z-]|$) ]] \
   || [[ " $* " =~ (^|[^a-z-])com\.eldato\.orchestrator-watchdog([^a-z-]|$) ]]; then
  printf 'REFUSED: a selftest tried to address a PRODUCTION launchd label: %s\n' "$*" >&2
  exit 97
fi
printf 'Bad request.\nCould not find service in domain for user gui: 0\n' >&2
exit 1
SH
chmod +x "$GSTUB/launchctl"
PATH="$GSTUB:$PATH"; export PATH
echo "==> offline self-test ($HERE)"

# ── 1) every script parses ───────────────────────────────────────────────────────
# ⛔ #2930 — RUNTIME AND TEST SUITES ARE NOT THE SAME RISK, AND THIS SWEEP USED TO BLOCK ON BOTH.
# `harness-up up` REFUSES to start on a failed self-test, so a `*.test.sh` that does not parse on THIS
# host used to stop a healthy controller from starting at all — the catch-22 `install.sh` had, one
# level up, and it has already happened twice (this file's own comment above records the 3.2 `case`
# pattern, and #2930 records `merge-reminder.test.sh`). A RUNTIME script still refuses: the controller
# executes it and launchd would crash-loop. A TEST suite is reported BY NAME and never counted as a
# failure — it cannot affect the runtime, and the class is gated before merge by
# scripts/check-bash32-parse.sh (a real bash 3.2 over every shipped `*.sh`, in both CI lanes).
rc=0
for f in "$HERE"/*.sh "$HERE"/retired/*.sh; do
  [ "$(basename "$f")" = "selftest.sh" ] && continue
  case "$(basename "$f")" in
    *.test.sh)
      if ! _err="$(bash -n "$f" 2>&1)"; then
        echo "      syntax error in the TEST suite $(basename "$f") — reported, NOT fatal (#2930):"
        printf '%s\n' "$_err" | sed 's/^/        /'
      fi
      ;;
    *)
      bash -n "$f" || { echo "      syntax error: $f"; rc=1; }
      ;;
  esac
done
ck "all shell scripts parse (bash -n)" $rc

# ── 2) the shipped sess() matches session names exactly ──────────────────────────
# Extracted from orch-loop.sh and driven against a fake `tmux`, so this pins the real function.
# `tmux has-session -t fix-82` prefix-matches `fix-820`, which starved PRs whose number prefixes
# a running worker's session name.
# sess() is a one-liner, so extract the single line (a range to /^}/ would swallow the whole loop).
grep -m1 '^sess() {' "$LOOP" > "$TMP/sess.sh"
if need "$TMP/sess.sh" "sess() is extracted from the shipped orch-loop.sh"; then
  # ⛔ DRIVEN THROUGH THE LAUNCHER, because that is what sess() delegates to now
  # (worker-terminal.sh): the census covers a durable TERMINAL as well as a tmux session, and a
  # sess() that matched only one of them lets two workers own one PR. The fake `cmux` below is the
  # surface, so the whole path — sess -> launcher -> the daemon's own tree read — is the shipped one.
  cmux() {
    case "${1:-}" in
      tree) printf '%s\n' '{"workspaces":[{"id":"ws_10","name":"wt-fix-820"},{"id":"ws_11","name":"wt-merge-821"},{"id":"ws_12","name":"wt-lane-5"}],"screens":[{"id":"s_10","workspace_id":"ws_10","layout":{"root":{"tab_ids":["t_10"]}}},{"id":"s_11","workspace_id":"ws_11","layout":{"root":{"tab_ids":["t_11"]}}},{"id":"s_12","workspace_id":"ws_12","layout":{"root":{"tab_ids":["t_12"]}}}],"tabs":[{"id":"t_10","content_id":"term_10"},{"id":"t_11","content_id":"term_11"},{"id":"t_12","content_id":"term_12"}],"terminals":[{"id":"term_10","running":true},{"id":"term_11","running":true},{"id":"term_12","running":true}]}' ;;
      *) : ;;
    esac
    return 0
  }
  O="$TMP/sessO"; mkdir -p "$O/state"; WT_DIR="$O/state"; WT_TABLE_TTL=0
  # shellcheck disable=SC1090
  . "$HERE/worker-terminal.sh"
  # shellcheck disable=SC1090
  . "$TMP/sess.sh"
  sess "fix-82"  && rc=1 || rc=0; ck "shipped sess(): fix-82 does NOT match fix-820" $rc
  sess "fix-820" && rc=0 || rc=1; ck "shipped sess(): fix-820 matches its own name (durable terminal)" $rc
  sess "fix-8200" && rc=1 || rc=0; ck "shipped sess(): fix-8200 does NOT match fix-820" $rc
  sess "merge-821" && rc=0 || rc=1; ck "shipped sess(): a second durable terminal is named too" $rc
  WT_TABLE=""; WT_TABLE_AT=0
  unset -f cmux
fi

# ── 3) the shipped classifier is fail-closed on ai-review-gate ───────────────────
# ⛔ THE CLASSIFIER IS A FILE, NOT A HEREDOC ANY MORE (agent-infra#2719). It lived in orch-loop.sh as an
# inline `python3 -c` string, and the NOCHECKS arm has to ask the SAME question on a re-read — two
# copies of these rules is how the harness and the merge rail disagreed before (#1714). So the shipped
# artifact IS `check-class.py`: a missing file is a hard FAIL here (never a silently empty classifier,
# which would grade GREEN on an empty answer). The required set and the review-gate NAME are still read
# from the ENVIRONMENT (agent-infra#1764), so the driver supplies them the same way the loop does.
CL_REQ="ai-review-gate python-ci-gate docs test-isolation license-surface legal-e2e pricing-artifact"
CL_GATE="ai-review-gate"
cat "$HERE/check-class.py" > "$TMP/classify.py" 2>/dev/null || : > "$TMP/classify.py"
cl() { printf '%s' "$1" | REQ="$CL_REQ" REVIEW_GATE="$CL_GATE" python3 "$TMP/classify.py" 2>/dev/null; }
# clreq <required-set> <payload> [<review-gate>] — the SAME shipped classifier against an
# ARBITRARY repo's required set. Used by the repo-shape fixtures below, and by test-gates.sh.
clreq() { printf '%s' "$2" | REQ="$1" REVIEW_GATE="${3:-ai-review-gate}" python3 "$TMP/classify.py" 2>/dev/null; }
if need "$TMP/classify.py" "the classifier is the shipped check-class.py"; then
got="$(cl '[{"name":"ai-review-gate","state":"SKIPPED"},{"name":"docs","state":"SKIPPED"}]')"
[ "$got" = "FAILED:ai-review-gate" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: ai-review-gate SKIPPED is not satisfied" $rc
got="$(cl '[{"name":"ai-review-gate","state":"NEUTRAL"}]')"
[ "$got" = "FAILED:ai-review-gate" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: ai-review-gate NEUTRAL is not satisfied" $rc
got="$(cl '[{"name":"docs","state":"SUCCESS"}]')"
[ "$got" = "FAILED:ai-review-gate" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: a missing ai-review-gate row is not satisfied" $rc
got="$(cl '[{"name":"ai-review-gate","state":"SUCCESS"},{"name":"python-ci-gate","state":"SUCCESS"},{"name":"docs","state":"SKIPPED"},{"name":"test-isolation","state":"SUCCESS"},{"name":"license-surface","state":"SUCCESS"},{"name":"legal-e2e","state":"NEUTRAL"},{"name":"pricing-artifact","state":"SUCCESS"}]')"
[ "$got" = "GREEN" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: gate SUCCESS + path-filtered legs skipped = GREEN" $rc
got="$(cl '[{"name":"ai-review-gate","state":"FAILURE"}]')"
[ "$got" = "FAILED:ai-review-gate" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: gate FAILURE is reported failed" $rc
# (z) THE REPO SHAPE THAT WAS DEADLOCKED (agent-infra#1764). Measured live on agent-infra PR #1763:
# 22 checks, every one SUCCESS/NEUTRAL, and ZERO `ai-review-gate` runs — against agent-infra's OWN
# required set (`pipeline-compliance`). The pre-fix classifier named `ai-review-gate` as the
# authority by CONSTANT, so `gate` was empty, `gate_ok` false, and it forced
# `FAILED:ai-review-gate` here: no PR could ever read GREEN and the merge queue could not drain.
# Exact verdict, so a regression to the constant (or any re-introduced absence-is-RED rule for a
# name this repo does not require) is RED.
got="$(clreq 'pipeline-compliance' '[{"name":"vendor-drift","state":"SUCCESS"},{"name":"cost-config","state":"SUCCESS"},{"name":"verify","state":"SUCCESS"},{"name":"admin-merge","state":"SUCCESS"},{"name":"drift-check","state":"SUCCESS"},{"name":"ci / lint","state":"SUCCESS"},{"name":"sigpipe-grep","state":"SUCCESS"},{"name":"bash-suites","state":"SUCCESS"},{"name":"http-pool-hygiene","state":"SUCCESS"},{"name":"ci / skill-lint","state":"SUCCESS"},{"name":"ci / script-validate","state":"SUCCESS"},{"name":"test","state":"SUCCESS"},{"name":"pi-config-extensions","state":"SUCCESS"},{"name":"setup-suite","state":"SUCCESS"},{"name":"ci / unit-test","state":"SUCCESS"},{"name":"ci / typecheck","state":"SUCCESS"},{"name":"search-cost","state":"SUCCESS"},{"name":"workflow-lock","state":"SUCCESS"},{"name":"workflow-drift","state":"SUCCESS"},{"name":"actionlint","state":"SUCCESS"},{"name":"pipeline-compliance","state":"SUCCESS"},{"name":"Mergify Merge Queue","state":"NEUTRAL"}]')"
[ "$got" = "GREEN" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: agent-infra's shape (22 checks, no ai-review-gate) reads GREEN on its own required set" $rc
# (z2) …and the scoping above does NOT weaken the fail-closed rule INSIDE that set: a required
# check this repo has not reported stays PENDING, never GREEN ("a missing check is not a green
# check"), and a red one stays RED.
got="$(clreq 'pipeline-compliance' '[{"name":"ci / lint","state":"SUCCESS"}]')"
[ "$got" = "PENDING:pipeline-compliance" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: a required check that never reported is PENDING, not GREEN" $rc
got="$(clreq 'pipeline-compliance' '[{"name":"pipeline-compliance","state":"FAILURE"}]')"
[ "$got" = "FAILED:pipeline-compliance" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: a red required check is FAILED on a non-review-gate repo" $rc

# ── 3b) the classifier's POLARITY — an allow-list, not a deny-list ───────────────
# agent-infra#1714: the classifier named the red conclusions and filed EVERYTHING ELSE as PENDING,
# so an unrecognised or null conclusion reached `gh pr merge --auto` (fail OPEN), while CANCELLED —
# non-red, a superseded run is normal — was named red and routed to the fixer. The rule is the one
# admin-merge.sh and record-review.sh already implement, so these fixtures pin the shipped
# classifier TO THAT RULE rather than to a copy of it.
#
# What each check below is EVIDENCE FOR, stated rather than overclaimed: measured against the
# pre-fix tree (this file dropped in beside the deny-list scripts), the polarity fixtures fail
# there — EXCEPT those whose subject predates this change (red stays red, an empty surface is not
# green) and the §3d shell checks, which guard the backtick hazard this change's own comment text
# introduces (the deny-list base has no such comments, so they pass there by construction). Those
# are regression guards, not evidence for the polarity; the fixtures that DO discriminate assert an
# exact verdict, never "not GREEN" (an empty string from a crashed extractor satisfies any negative
# assertion).
full() { # full <required-name> <state|conclusion, or the literal null> -> a full required surface
  python3 - "$1" "$2" <<'PY'
import json,sys
n,s=sys.argv[1],sys.argv[2]
rows=[{"name":x,"state":"SUCCESS"} for x in ("ai-review-gate","python-ci-gate","docs",
      "test-isolation","license-surface","legal-e2e","pricing-artifact")]
for r in rows:
    if r["name"]==n: r["state"]=None if s=="null" else s
print(json.dumps(rows))
PY
}
allstates() { # allstates <state|conclusion> -> every required row carrying that same state
  python3 - "$1" <<'PY'
import json,sys
s=sys.argv[1]
print(json.dumps([{"name":x,"state":s} for x in ("ai-review-gate","python-ci-gate","docs",
      "test-isolation","license-surface","legal-e2e","pricing-artifact")]))
PY
}
# (a) THE FALSE-GREEN: a null conclusion is RED, never PENDING (PENDING arms auto-merge).
got="$(cl "$(full docs null)")"
[ "$got" = "FAILED:docs" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: a null conclusion is RED, not PENDING" $rc
# (b) a conclusion GitHub has not documented is RED too — the allow-list, not a red-token list.
got="$(cl "$(full docs MYSTERY_FAILURE)")"
[ "$got" = "FAILED:docs" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: an unrecognised conclusion is RED, not PENDING" $rc
# (c) an unrecognised STATUS is judged by its conclusion (the rail's #1353 shape): null -> RED.
got="$(cl '[{"name":"ai-review-gate","status":"completed","conclusion":"success"},{"name":"docs","status":"completely_finished","conclusion":null}]')"
[ "$got" = "FAILED:docs" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: an unrecognised status with a null conclusion is RED" $rc
# (d) CANCELLED/STALE are NON-RED: a superseded run must not block the merge.
got="$(cl "$(full python-ci-gate CANCELLED)")"
[ "$got" = "GREEN" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: CANCELLED does not block (non-red)" $rc
got="$(cl "$(full legal-e2e STALE)")"
[ "$got" = "GREEN" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: STALE does not block (non-red)" $rc
# (e) …but they are NOT green either: a surface of nothing but cancelled/stale proves nothing,
# so it must never read GREEN (a skipped/cancelled shard is not coverage — the rail's doctrine).
# The FULL required surface, every row cancelled/stale INCLUDING the gate — the gate rule is what
# refuses it, and asserting the EXACT verdict pins that. An inexact "!= GREEN" would pass on the
# deny-list too (it reads every CANCELLED row as red, i.e. FAILED), so this fixture would prove
# nothing about the polarity; the exact form discriminates.
got="$(cl "$(allstates CANCELLED)")"
[ "$got" = "FAILED:ai-review-gate" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: an all-cancelled surface cannot read GREEN (the gate refuses it)" $rc
# STALE across the WHOLE surface, with the gate a real success: non-red rows must not force
# PENDING. Exact verdict, so the deny-list (which names no STALE token at all and reads them as
# neither ok nor bad) gives PENDING and fails here.
got="$(cl "$(python3 - <<'PY'
import json
print(json.dumps([{"name":"ai-review-gate","state":"SUCCESS"}]+[{"name":x,"state":"STALE"} for x in
      ("python-ci-gate","docs","test-isolation","license-surface","legal-e2e","pricing-artifact")]))
PY
)")"
[ "$got" = "GREEN" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: STALE rows across the surface do not force PENDING (non-red)" $rc
# (f) an EMPTY surface is not green — a missing check is not a green check (absence != green).
got="$(cl '[]')"
[ "$got" = "NOCHECKS" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: an EMPTY check surface is NOCHECKS, not GREEN" $rc
got="$(cl '{}')"
[ "$got" = "NOCHECKS" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: an unreadable payload is NOCHECKS, not GREEN" $rc
# (g) RED beats PENDING and beats the greens: a completed red is final.
got="$(cl "$(full docs FAILURE)")"
[ "$got" = "FAILED:docs" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: a red among several green is RED" $rc
got="$(cl '[{"name":"ai-review-gate","state":"SUCCESS"},{"name":"docs","state":"FAILURE"},{"name":"python-ci-gate","state":"IN_PROGRESS"}]')"
[ "$got" = "FAILED:docs" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: a red is final — it is not masked by an in-flight check" $rc
# (h) grouping is per (app, name): one app's result must not mask the other's. The red row is
# placed FIRST and a non-red row LAST, so the pre-fix per-name map (last write wins) reads NEUTRAL
# and this fixture fails there — with the red last it would pass on the deny-list and prove nothing.
got="$(cl '[{"name":"ai-review-gate","state":"SUCCESS"},{"name":"docs","state":"FAILURE","workflow":"w2"},{"name":"docs","state":"NEUTRAL","workflow":"w1"}]')"
[ "$got" = "FAILED:docs" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: a same-named check under two apps cannot mask a red" $rc
# (i) the NEWEST attempt by id governs (the check-runs API shape). Assert the EXACT verdict, never
# a "not FAILED" match — an empty string from a crashed extractor satisfies that form (the pre-fix
# classifier raises TypeError on this payload and prints nothing).
got="$(cl '{"check_runs":[{"id":1,"name":"ai-review-gate","status":"completed","conclusion":"success","app":{"slug":"a"}},{"id":5,"name":"docs","status":"completed","conclusion":"failure","app":{"slug":"a"}},{"id":9,"name":"docs","status":"completed","conclusion":"success","app":{"slug":"a"}}]}')"
[ "$got" = "PENDING:python-ci-gate,test-isolation,license-surface,legal-e2e,pricing-artifact" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: a newer passing attempt supersedes an older red" $rc
# (i2) …and it is by ID, not by position: with the NEWEST attempt listed FIRST and the older red
# LAST, "last row wins" would read the red. Pinned in both directions, so a regression to
# last-wins cannot survive whichever order an API happens to return.
got="$(cl '{"check_runs":[{"id":1,"name":"ai-review-gate","status":"completed","conclusion":"success","app":{"slug":"a"}},{"id":9,"name":"docs","status":"completed","conclusion":"success","app":{"slug":"a"}},{"id":5,"name":"docs","status":"completed","conclusion":"failure","app":{"slug":"a"}}]}')"
[ "$got" = "PENDING:python-ci-gate,test-isolation,license-surface,legal-e2e,pricing-artifact" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: the newest attempt by id governs even when it is not the last row" $rc
got="$(cl '{"check_runs":[{"id":1,"name":"ai-review-gate","status":"completed","conclusion":"success","app":{"slug":"a"}},{"id":12,"name":"docs","status":"completed","conclusion":"failure","app":{"slug":"a"}},{"id":9,"name":"docs","status":"completed","conclusion":"success","app":{"slug":"a"}}]}')"
[ "$got" = "FAILED:docs" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: a newest-by-id red is not masked by a later-listed older green" $rc
got="$(cl '{"check_runs":[{"id":1,"name":"ai-review-gate","status":"completed","conclusion":"success","app":{"slug":"a"}},{"id":9,"name":"docs","status":"completed","conclusion":"success","app":{"slug":"a"}},{"id":12,"name":"docs","status":"completed","conclusion":"failure","app":{"slug":"a"}}]}')"
[ "$got" = "FAILED:docs" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped classifier: a newer failing attempt supersedes an older green" $rc
fi

# ── 3c) the fixer's failing-check list uses the SAME polarity (agent-infra#1714) ──
# The loop hands a red required check to fix-one.sh; its list named CANCELLED as failing, so a
# normally-superseded run burned a capped fixer attempt on a PR that was not red. Extracted from
# the shipped fix-one.sh, so this pins the real list rather than a re-implementation of it.
awk '/^FAILING_CHECKS="/,/^" 2>\/dev\/null\)"$/' "$HERE/fix-one.sh" \
  | sed -n '/^import sys,json$/,$p' | sed '/^" 2>\/dev\/null)"$/d' > "$TMP/failing_checks.py"
fc() { printf '%s' "$1" | python3 "$TMP/failing_checks.py" 2>/dev/null; }
if need "$TMP/failing_checks.py" "the fixer's failing-check list is extracted from fix-one.sh"; then
got="$(fc '[{"name":"docs","state":"FAILURE"},{"name":"legal-e2e","state":"CANCELLED"},{"name":"test-isolation","state":"STALE"},{"name":"license-surface","state":"NEUTRAL"}]')"
[ "$got" = "docs" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped fixer list: CANCELLED/STALE are not handed to the fixer" $rc
got="$(fc '[{"name":"docs","state":null},{"name":"legal-e2e","state":"MYSTERY_FAILURE"}]')"
[ "$got" = "docs legal-e2e" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped fixer list: a null/unrecognised state IS handed to the fixer (fail closed)" $rc
got="$(fc '[{"name":"docs","state":"SUCCESS"},{"name":"python-ci-gate","state":"IN_PROGRESS"}]')"
[ -z "$got" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "shipped fixer list: a green/in-flight surface yields no failing check" $rc
fi

# ── 3d) the classifier travels through BASH: no backtick command-substitution ────
# The checks above extract the Python with awk/sed, so they never exercise the shell. The
# classifier is built as `V="$(… | python3 -c " <python> ")"`; an UNESCAPED backtick inside that
# double-quoted string is COMMAND-SUBSTITUTED by bash before Python ever sees it. A comment that
# spells `gh pr merge --auto` therefore RAN that command every cycle (the exact fail-open this
# PR exists to close), and a backticked `gh pr checks` spliced a multi-line table into the Python
# source (SyntaxError -> V="" -> no case arm matched). Extract the real assignment and drive it
# through a logged `gh` shim so the shell, not an awk extraction, is what runs.
# ⛔ THE ASSIGNMENT IS ONE LINE NOW (agent-infra#2719): the Python moved to `check-class.py`, so the
# heredoc's closing `" 2>/dev/null)"` terminator no longer exists — the old range-capture ran to the END
# OF THE FILE (1547 lines measured) and the driver then aborted on `set -u` before printing `V`, which
# made this whole block report a red it could not explain. Capture the ONE assignment line.
grep -m1 '^    V="\$(gh pr checks' "$LOOP" > "$TMP/classify_bash.sh"
if need "$TMP/classify_bash.sh" "the classifier's bash assignment is extracted from orch-loop.sh"; then
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'GH_INVOKED: %s\n' "$*" >> "$GH_LOG"
if [ "${1:-}" = "pr" ] && [ "${2:-}" = "checks" ]; then
  printf '[{"name":"ai-review-gate","state":"SUCCESS"},{"name":"python-ci-gate","state":"SUCCESS"},{"name":"docs","state":"SUCCESS"},{"name":"test-isolation","state":"SUCCESS"},{"name":"license-surface","state":"SUCCESS"},{"name":"legal-e2e","state":"SUCCESS"},{"name":"pricing-artifact","state":"SUCCESS"}]'
fi
exit 0
SH
  chmod +x "$TMP/bin/gh"
  # Assemble a driver: the real assignment verbatim, with the bash-side inputs it reads.
  {
    printf '%s\n' 'set -u'
    printf '%s\n' "OR='example/repo'"
    printf '%s\n' 'PR=8518'
    printf '%s\n' "REQ='ai-review-gate python-ci-gate docs test-isolation license-surface legal-e2e pricing-artifact'"
    printf '%s\n' "REVIEW_GATE='ai-review-gate'"
    # the pipeline's classifier path is resolved by the loop at startup; the driver supplies the
    # SHIPPED file so the shell runs the real classifier, not a missing path.
    printf '%s\n' "_CK_PY='$HERE/check-class.py'"
    cat "$TMP/classify_bash.sh"
    printf '%s\n' 'printf "V=%s\n" "$V"'
  } > "$TMP/drive.sh"
  # Only the pipeline's own `gh pr checks <PR> --json …` may run. A `pr merge` (or a bare
  # `pr checks`) in the log is a backtick leaking out of a comment as an executed command.
  : > "$TMP/gh.log"
  out="$(PATH="$TMP/bin:$PATH" GH_LOG="$TMP/gh.log" bash "$TMP/drive.sh" 2>"$TMP/drive.err")"
  n="$(wc -l < "$TMP/gh.log" | tr -d ' ')"
  [ "$n" = "1" ] && rc=0 || { rc=1; echo "      gh calls ($n): $(tr '\n' ';' < "$TMP/gh.log")"; }
  ck "shipped classifier: comments are not executed as commands (exactly one gh call)" $rc
  if grep -q 'pr merge' "$TMP/gh.log" 2>/dev/null; then rc=1; else rc=0; fi
  ck "shipped classifier: no backticked \`gh pr merge\` escapes from a comment" $rc
  if grep -q 'command not found' "$TMP/drive.err" 2>/dev/null; then rc=1; else rc=0; fi
  ck "shipped classifier: no backticked word is run as a command" $rc
  case "$out" in *V=GREEN*) rc=0;; *) rc=1; echo "      out: $out";; esac
  ck "shipped classifier: the bash substitution still yields GREEN" $rc
fi

# ── 4) the shipped claim block refuses a second owner ────────────────────────────
# Extracted from merge-one.sh and executed, so this pins the real lock, not a copy of the idiom.
sed -n '/^CLAIM="\$O\/state\/mergeclaim-\$PR.lock"/,/^trap .rm -f "\$CLAIM".*$/p' "$MERGE" > "$TMP/claim.sh"
mkdir -p "$TMP/O/state"
if need "$TMP/claim.sh" "the claim block is extracted from the shipped merge-one.sh"; then
# The claim block logs to "$L.log", so assert on the log, not on stdout.
# (a) a claim held by a LIVE pid must be refused
printf '%s' "$$" > "$TMP/O/state/mergeclaim-900.lock"
out="$( O="$TMP/O" PR=900 L="$TMP/claimtest" bash -c "set -u; . '$TMP/claim.sh'; echo ALIVE" 2>&1 )"
if grep -q 'already owns this PR' "$TMP/claimtest.log" 2>/dev/null; then rc=0; else rc=1; echo "      log: $(cat "$TMP/claimtest.log" 2>/dev/null)"; fi
ck "shipped claim block: a live owner is refused" $rc
case "$out" in *ALIVE*) rc=1;; *) rc=0;; esac
ck "shipped claim block: the refused worker does not proceed" $rc
# (b) a claim held by a DEAD pid must be reclaimed
printf '%s' "999999" > "$TMP/O/state/mergeclaim-901.lock"
out="$( O="$TMP/O" PR=901 L="$TMP/claimtest2" bash -c "set -u; . '$TMP/claim.sh'; echo ALIVE" 2>&1 )"
case "$out" in *ALIVE*) rc=0 ;; *) rc=1; echo "      got '$out'";; esac
ck "shipped claim block: a dead owner's claim is reclaimed" $rc
fi
# (c) ORDERING PIN (P2, 2026-10-14 review): the local lock must be taken BEFORE the log is
# truncated, or a losing duplicate wipes the live winner's log (and its "cross-box claim:
# acquired …" evidence) on its way to discovering it does not own the PR. Structural on the
# shipped file, so the pre-fix ordering (truncate before the lock) is RED.
lock_ln="$(grep -nF 'CLAIM="$O/state/mergeclaim-$PR.lock"' "$MERGE" | head -1 | cut -d: -f1)"
trunc_ln="$(grep -nF '[merge $PR] start' "$MERGE" | head -1 | cut -d: -f1)"
if [ -n "$lock_ln" ] && [ -n "$trunc_ln" ] && [ "$lock_ln" -lt "$trunc_ln" ]; then rc=0; else rc=1; echo "      lock line=$lock_ln truncation line=$trunc_ln"; fi
ck "shipped merge-one: the local lock is taken BEFORE the log is truncated" $rc

# ── 5) the shipped reaper un-blacklists only undelivered dispatches ──────────────
# Extracted from refresh-candidates.sh and run against fixtures:
#   4114 = open, no PR, no lane        -> must be REAPED
#   8888 = open, PR exists             -> must be KEPT
#   9999 = not open                    -> must be KEPT
#   7777 = a live lane-7777 session    -> must be KEPT
R="$TMP/reap"; mkdir -p "$R"
printf '4114\n8888\n9999\n7777\n' > "$R/dispatched.txt"
printf '4114\n8888\n9999\n' > "$R/checked.txt"
printf '4114\n8888\n' > "$R/.open_iss"
printf 'feat/8888-tm\n' > "$R/.pr_brs"
tmux() { printf 'lane-7777\nmerge-100\n'; }
# extract the embedded reaper (the heredoc body only). The invocation carries a repo slug for the
# landed prune (tortoise#8560), so the anchor tolerates ANY second argument — pinned to the SHAPE, not
# to one argument list. ⛔ IT WAS PINNED TO `"$OR"` AND THAT BROKE SILENTLY (review P1-adjacent, cycle
# 4): the prune's argument became `"$PRUNE_OR"` (explicit-or-derived, never the fallback literal), the
# regex stopped matching, the extraction produced an EMPTY file, and every landed/reaper assertion
# below ran against nothing instead of failing. A narrow anchor here is a false PASS generator.
awk '/^python3 - "\$O"( "[^"]*")? <<.PY.$/{f=1;next} /^PY$/{f=0} f' "$REFRESH" > "$R/reap.py"
# ⛔ AND THE ANCHOR'S TOLERANCE IS ITSELF ASSERTED (review P2, cycle 5). A permissive anchor that
# silently accepts ONE argument is the false-PASS generator above one layer up: nothing here runs
# refresh-candidates.sh in refresh mode, so a regression to `python3 - "$O" <<'PY'` would leave every
# landed assertion below green while production kept every entry forever. Pin the SHIPPED line to
# "$O plus a variable holding the slug", which is the contract the extraction relies on.
grep -qE '^python3 - "\$O" "\$[A-Z_]+" <<.PY.$' "$REFRESH" && rc=0 || rc=1
ck "the reaper is invoked with an explicit slug argument (\$O + a repo variable), so its prune CAN ask" $rc
if need "$R/reap.py" "the reaper is extracted from the shipped refresh-candidates.sh"; then
# the extracted body shells out to tmux; export the fake so the child sees it
cat > "$R/tmux" <<'SH'
#!/bin/bash
printf 'lane-7777\nmerge-100\n'
SH
chmod +x "$R/tmux"
# the landed prune shells out to `gh issue view <N> --repo <slug> --json state` (UNCAPPED, per
# entry). The fake answers from GH_STUB_OPEN (`<N> ...` = open, anything else = closed), and
# GH_STUB_FAIL=1 is the unreadable case — which must KEEP the entry, never assume closed.
cat > "$R/gh" <<'SH'
#!/bin/bash
if [ "${GH_STUB_FAIL:-0}" = "1" ]; then
  echo "gh: could not reach api.github.com" >&2; exit 1
fi
case " ${GH_STUB_OPEN:-} " in *" $3 "*) echo '{"state":"OPEN"}'; exit 0;; esac
echo '{"state":"CLOSED"}'
SH
chmod +x "$R/gh"
( PATH="$R:$PATH" python3 "$R/reap.py" "$R" ) > "$TMP/reap.out" 2>&1
kept="$(tr '\n' ' ' < "$R/dispatched.txt")"
case "$kept" in *4114*) rc=1;; *) rc=0;; esac
ck "shipped reaper: open+no-PR+no-lane dispatch is un-blacklisted" $rc
case "$kept" in *8888*) rc=0;; *) rc=1;; esac
ck "shipped reaper: an issue with a PR is kept" $rc
case "$kept" in *9999*) rc=0;; *) rc=1;; esac
ck "shipped reaper: a closed issue is kept" $rc
case "$kept" in *7777*) rc=0;; *) rc=1;; esac
ck "shipped reaper: an issue with a live lane is kept" $rc
case "$(tr '\n' ' ' < "$R/checked.txt")" in *4114*) rc=1;; *) rc=0;; esac
ck "shipped reaper: the reaped entry is removed from checked.txt" $rc

# ── 5a) a FAILED listing must not be read as "no PRs" ────────────────────────────────────────
# The capture (line above the heredoc) DELETES the list when `gh` fails, and the guard at the top of
# the extracted reaper refuses the pass when either list is ABSENT. These cases pin BOTH halves:
# an ABSENT list = the read FAILED = reap NOTHING; a PRESENT but EMPTY list = a real answer = reap.
# Pre-fix, an absent/empty `.pr_brs` made `has_pr` false for every issue and 8888 — which HAS a PR
# in the populated control above — was un-blacklisted and re-dispatched. (agent-infra#1705)
RF="$TMP/reap-failpr"; mkdir -p "$RF"
printf '4114\n8888\n' > "$RF/dispatched.txt"
printf '4114\n8888\n' > "$RF/checked.txt"
printf '4114\n8888\n' > "$RF/.open_iss"
# .pr_brs deliberately ABSENT: this is the shape the shipped capture leaves on a failed `gh pr list`
( PATH="$R:$PATH" python3 "$R/reap.py" "$RF" ) > "$TMP/reap-failpr.out" 2>&1
kept="$(tr '\n' ' ' < "$RF/dispatched.txt")"
case "$kept" in *4114*8888*) rc=0;; *) rc=1; echo "      dispatched.txt: '$kept'";; esac
ck "shipped reaper: an UNREADABLE PR listing reaps NOTHING (both entries kept)" $rc
case "$(tr '\n' ' ' < "$RF/checked.txt")" in *4114*8888*) rc=0;; *) rc=1;; esac
ck "shipped reaper: an UNREADABLE PR listing leaves checked.txt untouched" $rc
grep -q 'SKIPPED' "$TMP/reap-failpr.out" && rc=0 || rc=1
ck "shipped reaper: the skipped pass says so (an unreadable listing is not an empty one)" $rc
# the same guard for the neighbouring `.open_iss` probe, which had the safe polarity by accident
RO="$TMP/reap-failopen"; mkdir -p "$RO"
printf '4114\n8888\n' > "$RO/dispatched.txt"
# 5252 is checked and has NO local keep-fact (not queued, not dispatched, no PR, no lane): it is the
# entry the CHECKED classification must publish as releasable even though `.open_iss` is unreadable.
printf '4114\n8888\n5252\n' > "$RO/checked.txt"
printf 'feat/8888-tm\n' > "$RO/.pr_brs"
( PATH="$R:$PATH" python3 "$R/reap.py" "$RO" ) > "$TMP/reap-failopen.out" 2>&1
case "$(tr '\n' ' ' < "$RO/dispatched.txt")" in *4114*) rc=0;; *) rc=1;; esac
ck "shipped reaper: an UNREADABLE open-issue listing reaps nothing either" $rc
# ⛔ The outcome above is NOT discriminating on its own, and that was verified by mutation.
# With `.open_iss` absent the reaper's `open_iss` set is EMPTY, so `n in open_iss` is false for
# every entry and every entry is kept by the SAFE polarity -- with or without the guard. Dropping
# `.open_iss` from the guard tuple, or removing the guard entirely, leaves the check above GREEN.
# Assert the guard's OWN signature instead: the skipped pass must NAME the missing list. That is
# what the guard produces and what the pre-fix `|| : >` shape could not.
grep -qF 'SKIPPED: .open_iss' "$TMP/reap-failopen.out" && rc=0 || rc=1
ck "shipped reaper: the open-issue guard fires and names .open_iss (not vacuously safe)" $rc
# ⛔ THE GUARD IS *SPLIT*, AND THIS IS ITS ONLY DISCRIMINATING ASSERTION (review P2, #2183). An
# unreadable `.open_iss` must disable ONLY the `dispatched.txt` reap; the CHECKED classification
# reads `candidates.txt`/`dispatched.txt`/`.pr_brs`/`tmux`/the claim registry and must still run.
# Re-joining the guards (refusing both on either missing listing) leaves every assertion above
# GREEN — the old single message also carries `SKIPPED: .open_iss` and `dispatched.txt` is
# untouched under both — so only the ARTIFACT below can tell the two designs apart. 5252 has no
# keep-fact and must be published as releasable; a re-joined guard publishes nothing, and the
# entry stays suppressed for ever, which is the defect this patch removes.
relopen="$(tr '\n' ' ' < "$RO/state/checked-release-candidates" 2>/dev/null)"
case "$relopen" in *5252*) rc=0;; *) rc=1; echo "      releasable: '$relopen'";; esac
ck "shipped reaper: an unreadable open-issue listing still RUNS the checked classification (the guard is split)" $rc
# a PRESENT but EMPTY list is a REAL answer and must still reap
RE="$TMP/reap-emptypr"; mkdir -p "$RE"
printf '4114\n7777\n' > "$RE/dispatched.txt"
printf '4114\n7777\n' > "$RE/checked.txt"
printf '4114\n' > "$RE/.open_iss"   # 7777 is not open -> kept
: > "$RE/.pr_brs"                     # readable and empty: there are genuinely no PRs
( PATH="$R:$PATH" python3 "$R/reap.py" "$RE" ) > "$TMP/reap-emptypr.out" 2>&1
kept="$(tr '\n' ' ' < "$RE/dispatched.txt")"
case "$kept" in *4114*) rc=1;; *) rc=0;; esac
ck "shipped reaper: a genuinely EMPTY (readable) PR listing still reaps 4114" $rc
case "$kept" in *7777*) rc=0;; *) rc=1;; esac
ck "shipped reaper: the empty-listing pass still keeps a non-open issue (7777)" $rc

# ── 5a2) THE CHECKED CLASSIFICATION: a suppression survives only while a re-checkable fact holds ──
# `checked.txt` short-circuits the walk before ANY network call, so an entry in it is invisible to
# every later pass — and before agent-infra#2183 nothing revalidated it: the only remover walked
# `dispatched.txt`, a different file. A CLEAN-judged candidate that was never dispatched was therefore
# suppressed for ever. These fixtures drive the SHIPPED heredoc (extracted above) and assert the
# ARTIFACTS it publishes, never a log string.
#   CQ: 4114 no keep-fact -> RELEASABLE (the queue can fill again)
#   CQ: 5151 in candidates.txt -> kept as `queued`
#   CQ: 6161 has a PR head ref -> kept as `pr`
CK="$TMP/reap-checked"; mkdir -p "$CK"
printf '5151\n' > "$CK/candidates.txt"
printf '4114\n5151\n6161\n' > "$CK/checked.txt"
printf '6161\n' > "$CK/.pr_brs"
printf '4114\n5151\n6161\n' > "$CK/.open_iss"
( PATH="$R:$PATH" python3 "$R/reap.py" "$CK" ) > "$TMP/reap-checked.out" 2>&1
rel="$(tr '\n' ' ' < "$CK/state/checked-release-candidates" 2>/dev/null)"
case "$rel" in *4114*) rc=0;; *) rc=1;; esac
ck "shipped reaper: a checked entry with NO keep-fact is RELEASABLE (it is not suppressed for ever)" $rc
case "$rel" in *5151*|*6161*) rc=1;; *) rc=0;; esac
ck "shipped reaper: a queued or PR-backed checked entry is never released" $rc
kq="$(grep -c '^5151	queued$' "$CK/state/checked-kept" 2>/dev/null || :)"
[ "${kq:-0}" -eq 1 ]; rc=$?
ck "shipped reaper: the checked KEEP-FACT for a queued issue is recorded as 'queued'" $rc
kp="$(grep -c '^6161	pr$' "$CK/state/checked-kept" 2>/dev/null || :)"
[ "${kp:-0}" -eq 1 ]; rc=$?
ck "shipped reaper: the checked KEEP-FACT for a PR-backed issue is recorded as 'pr'" $rc
# ⛔ AND THE HEREDOC NEVER REWRITES checked.txt ITSELF: it publishes the classification and leaves the
# single release rewrite to the claim filter, so an entry the registry KEEPS never has to be put back.
ckx="$(tr '\n' ' ' < "$CK/checked.txt")"
case "$ckx" in *4114*5151*6161*) rc=0;; *) rc=1;; esac
ck "shipped reaper: the classification does NOT rewrite checked.txt (one release writer, later)" $rc
# ⛔ THE SPLIT GUARD, the other direction: an UNREADABLE `.pr_brs` refuses the whole classification and
# says so — releasing on the facts it happens to have would un-suppress entries that DO have a PR.
CP="$TMP/reap-checked-nopr"; mkdir -p "$CP"
printf '4114\n' > "$CP/checked.txt"
printf '4114\n' > "$CP/.open_iss"
( PATH="$R:$PATH" python3 "$R/reap.py" "$CP" ) > "$TMP/reap-checked-nopr.out" 2>&1
[ -f "$CP/state/checked-release-candidates" ]; rc=$?
[ "$rc" -eq 0 ] && rc=1 || rc=0
ck "shipped reaper: with no PR listing the checked classification publishes NO candidates" $rc
grep -q 'unjustified=-' "$CP/state/checked-reap" 2>/dev/null; rc=$?
ck "shipped reaper: a refused classification records unjustified=- (unknown, not 0)" $rc
grep -qF 'SKIPPED (checked: .pr_brs unreadable)' "$TMP/reap-checked-nopr.out"; rc=$?
ck "shipped reaper: the refused classification NAMES the missing listing" $rc
fi
unset -f tmux

# ── 5b) the shipped refresh loop never blacklists a candidate it did not pre-flight ─
# `echo "$N" >> checked.txt` sat BEFORE `n=$((n+1)); [ "$n" -gt "$LIMIT" ] && break`, so the
# (LIMIT+1)-th candidate was recorded as checked and then the loop broke without ever running
# collision_preflight.py for it. checked.txt suppresses that issue forever and the §7.1 reaper
# only un-blacklists dispatched.txt entries — so one dispatchable issue was lost per refresh.
awk '/^n=0$/{f=1} f{print} /^done < /{f=0}' "$REFRESH" > "$TMP/refreshloop.sh"
# ⛔ THIS FIXTURE IS THE WALK, NOT THE WHOLE PASS — STATED, BECAUSE IT BOUNDS WHAT THE LANDED
# ASSERTIONS BELOW CAN CLAIM (review P2, cycle 5). The extraction starts at `n=0` (the walk) and the
# shipped pass runs its REAPER — which contains the landed prune — EARLIER. So these cases hold a
# landed entry that the reaper would have dropped on a real second pass (its issue being CLOSED is
# what made it LANDED), and the "still reported on a later pass" assertion is only reachable here
# through the reaper's KEEP branch. That is deliberate: the walk's own contract (does a recorded
# LANDED entry suppress re-pre-flight and free a slot) is what this fixture isolates. The reaper's
# drop/release/keep behaviour is driven separately, against the extracted reaper body, below.
# ⛔ RESIDUAL: no fixture runs the two together, so a change in their ORDER is not covered here.
# ⛔ The loop body reads TWO variables the shipped script defines earlier in its flow: $PY (the
# interpreter) and $PREFLIGHT (the resolved tool path). agent-infra#1736 replaced the hardcoded
# `"$SC/.venv/bin/python" tools/collision_preflight.py` with those, so the extraction must supply
# them or the check would pass by running an empty command (no VERDICT) rather than the stub.
if need "$TMP/refreshloop.sh" "the refresh loop body is extracted from the shipped refresh-candidates.sh"; then
  # THE CLAIM VERDICT IS A SEPARATE CONTRACT, stubbed for the walk fixtures (agent-infra#2466). The
  # walk's own questions are "is this candidate consumed", "is it retried", "does a landed record free
  # a slot"; the cross-box claim read is pinned by §5b-bis below and by refresh-scout.test.sh's
  # claim-* cases. Without the stub every fixture here would take the fail-closed INCOMPLETE arm, which
  # is correct behaviour and the wrong fixture — the same shape as supplying $PY/$PREFLIGHT above.
  { printf '%s\n' 'issue_claim_verdict() { CLAIM_RESULT=""; return 0; }'
    cat "$TMP/refreshloop.sh"; } > "$TMP/refreshloop-drive.sh"
  RL="$TMP/refresh"; mkdir -p "$RL/fakesc/.venv/bin"
  printf '10\n20\n30\n40\n50\n' > "$RL/.pool"
  : > "$RL/checked.txt"; : > "$RL/candidates.txt"; : > "$RL/dispatched.txt"
  cat > "$RL/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
# stand-in for the scout's venv python: every candidate pre-flights CLEAN
echo "VERDICT: CLEAN"
PY
  chmod +x "$RL/fakesc/.venv/bin/python"
  O="$RL" LIMIT=3 SC="$RL/fakesc" PY="$RL/fakesc/.venv/bin/python" PREFLIGHT="$RL/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" > "$TMP/refreshloop.out" 2>&1
  checked="$(tr '\n' ' ' < "$RL/checked.txt")"
  case "$checked" in *40*) rc=1;; *) rc=0;; esac
  ck "shipped refresh loop: the candidate past LIMIT is NOT marked checked" $rc
  case "$checked" in *10*20*30*) rc=0;; *) rc=1;; esac
  ck "shipped refresh loop: the first LIMIT candidates are marked checked" $rc
  cands="$(tr '\n' ' ' < "$RL/candidates.txt")"
  case "$cands" in *10*20*30*) rc=0;; *) rc=1;; esac
  ck "shipped refresh loop: the pre-flighted CLEAN candidates reach the backlog" $rc

  # ⛔ THE FAIL-CLOSED CLAIM READ IS NOT DRIVEN HERE (agent-infra#2466), ON PURPOSE. This fixture
  # extracts the WALK, so `issue_claim_verdict` — the function that owns the missing-registry verdict —
  # is not defined in it, and a case here would grade the extraction's 127 fallback rather than the
  # shipped answer (measured: it "passed" while naming neither the registry nor the exit code). The
  # real contract is driven against the SHIPPED script in refresh-scout.test.sh's `claim-absent` case
  # (nothing queued, the refusal names the registry, the pass exits non-zero).

  # ── 5c) a pre-flight that produced NO verdict must not blacklist the issue ───────────────────
  # Same loop, but the stub python now fails the way a broken scout venv / API failure does: it
  # exits non-zero and emits no `VERDICT` line. The pre-fix loop wrote checked.txt BEFORE reading
  # the verdict, so the issue was consumed permanently and could never be re-attempted — and the
  # §7.1 reaper walks dispatched.txt only, so nothing ever removed that entry. (agent-infra#1716)
  RV="$TMP/verdict"; mkdir -p "$RV/fakesc/.venv/bin"
  printf '10\n' > "$RV/.pool"
  : > "$RV/checked.txt"; : > "$RV/candidates.txt"; : > "$RV/dispatched.txt"
  cat > "$RV/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
# stand-in for a pre-flight that ERRORED: no VERDICT line, non-zero exit
echo "boom: could not reach the graph" >&2
exit 1
PY
  chmod +x "$RV/fakesc/.venv/bin/python"
  O="$RV" LIMIT=5 SC="$RV/fakesc" PY="$RV/fakesc/.venv/bin/python" PREFLIGHT="$RV/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" > "$TMP/verdict.out" 2>&1
  case "$(tr '\n' ' ' < "$RV/checked.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "shipped refresh loop: an ERRORED pre-flight does NOT blacklist the issue" $rc
  case "$(tr '\n' ' ' < "$RV/candidates.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "shipped refresh loop: an ERRORED pre-flight queues nothing" $rc

  # ── 5d) a COLLISION is transient and must be re-attempted, not recorded forever ──────────────
  # The stub answers COLLISION on the first pass (a peer owns the issue) and CLEAN on the second
  # (the colliding work has landed). The pre-fix loop recorded checked.txt before the verdict, so
  # the issue was suppressed forever and the second pass never ran the pre-flight at all.
  RC="$TMP/collide"; mkdir -p "$RC/fakesc/.venv/bin"
  printf '10\n' > "$RC/.pool"
  : > "$RC/checked.txt"; : > "$RC/candidates.txt"; : > "$RC/dispatched.txt"
  cat > "$RC/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
# first pass: a peer's work is in flight; after it lands: CLEAN
S="$(dirname "$0")/.pass"
if [ -f "$S" ]; then echo "VERDICT: CLEAN"; else : > "$S"; echo "VERDICT: COLLISION"; fi
PY
  chmod +x "$RC/fakesc/.venv/bin/python"
  O="$RC" LIMIT=5 SC="$RC/fakesc" PY="$RC/fakesc/.venv/bin/python" PREFLIGHT="$RC/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" > "$TMP/collide-1.out" 2>&1
  case "$(tr '\n' ' ' < "$RC/checked.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "shipped refresh loop: a COLLISION does not permanently blacklist the issue" $rc
  case "$(tr '\n' ' ' < "$RC/candidates.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "shipped refresh loop: a COLLISION is not queued" $rc
  O="$RC" LIMIT=5 SC="$RC/fakesc" PY="$RC/fakesc/.venv/bin/python" PREFLIGHT="$RC/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" > "$TMP/collide-2.out" 2>&1
  case "$(tr '\n' ' ' < "$RC/candidates.txt")" in *10*) rc=0;; *) rc=1;; esac
  ck "shipped refresh loop: the COLLISION is re-attempted and queued once it clears" $rc

  # ── 5f) LANDED is SUPPRESSED and REPORTED, never blacklisted (tortoise#8560/#8625) ─────────────
  # A LANDED verdict means the issue is already shipped. It must not be queued, must not be written
  # to checked.txt (which would retire an OPEN issue from the backlog permanently and invisibly —
  # checked.txt is only pruned for a reaped DISPATCH, and a landed issue is never dispatched), and
  # the set must be NAMED on every pass, including ones where no new verdict arrives.
  RL2="$TMP/landed"; mkdir -p "$RL2/fakesc/.venv/bin"
  printf '10\n' > "$RL2/.pool"
  : > "$RL2/checked.txt"; : > "$RL2/candidates.txt"; : > "$RL2/dispatched.txt"; : > "$RL2/landed.txt"
  cat > "$RL2/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
# stand-in for a close-race LANDED pre-flight: a terminal verdict. Each invocation is counted so
# pass 2 can prove the recorded issue is not re-pre-flighted.
echo x >> "$(dirname "$0")/.calls"
echo "VERDICT: LANDED (exit 4) — 1 authoritative terminal signal(s)"
PY
  chmod +x "$RL2/fakesc/.venv/bin/python"
  O="$RL2" LIMIT=5 SC="$RL2/fakesc" PY="$RL2/fakesc/.venv/bin/python" PREFLIGHT="$RL2/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" > "$TMP/landed-1.out" 2>&1
  case "$(tr '\n' ' ' < "$RL2/landed.txt")" in *10*) rc=0;; *) rc=1;; esac
  ck "shipped refresh loop: a LANDED verdict is recorded in landed.txt (not checked.txt)" $rc
  case "$(tr '\n' ' ' < "$RL2/checked.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "shipped refresh loop: a LANDED issue is NOT blacklisted in checked.txt" $rc
  case "$(tr '\n' ' ' < "$RL2/candidates.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "shipped refresh loop: a LANDED verdict is NOT queued as a dispatch candidate" $rc
  case "$(cat "$TMP/landed-1.out")" in *"no verdict"*) rc=1;; *) rc=0;; esac
  ck "shipped refresh loop: a LANDED verdict is not logged as a missing verdict" $rc
  # ⛔ THE SUMMARY IS A PASS-TAIL BLOCK, not part of the extracted loop (which stops at `done`), so it
  # is exercised by EXTRACTING the shipped block and running it. A grep for its text would stay green
  # with the block deleted; an empty extraction is a failure, not a pass.
  awk '/^if \[ -s "\$O\/landed.txt" \]; then$/{f=1} f{print} f&&/^fi$/{exit}' "$REFRESH" > "$TMP/landedsum.sh"
  if need "$TMP/landedsum.sh" "the landed summary is extracted from the shipped refresh-candidates.sh"; then
    sum1="$(O="$RL2" bash "$TMP/landedsum.sh" 2>&1)"
    case "$sum1" in *"landed (awaiting verify/close"*"10"*) rc=0;; *) rc=1;; esac
    ck "shipped refresh: the landed set and its remedy are printed when it is recorded" $rc
  fi
  # a SECOND pass, where no new verdict arrives at all (the issue is skipped via landed.txt).
  O="$RL2" LIMIT=5 SC="$RL2/fakesc" PY="$RL2/fakesc/.venv/bin/python" PREFLIGHT="$RL2/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" > "$TMP/landed-2.out" 2>&1
  # ... and the set is still named on that later pass. That is what makes the entry a reported
  # decision instead of an invisible permanent suppression.
  sum2="$(O="$RL2" bash "$TMP/landedsum.sh" 2>&1)"
  case "$sum2" in *"landed (awaiting verify/close"*"10"*) rc=0;; *) rc=1;; esac
  ck "shipped refresh: the landed set is STILL reported on a later pass" $rc
  [ "$(wc -l < "$RL2/fakesc/.venv/bin/.calls" | tr -d ' ')" = "1" ] && rc=0 || rc=1
  ck "shipped refresh loop: a recorded LANDED issue is not re-pre-flighted on the next pass" $rc

  # ── 5g) a recorded LANDED entry frees the next pass's LIMIT slot (tortoise#8560) ──────────────
  # Pool 10 (LANDED once) then 20 (CLEAN), LIMIT=1. Pass 1 spends the single slot on 10; pass 2 must
  # walk past the landed entry BEFORE the slot counter, so 20 is pre-flighted and queued.
  RC2="$TMP/landed-cap"; mkdir -p "$RC2/fakesc/.venv/bin"
  printf '10\n20\n' > "$RC2/.pool"
  : > "$RC2/checked.txt"; : > "$RC2/candidates.txt"; : > "$RC2/dispatched.txt"; : > "$RC2/landed.txt"
  cat > "$RC2/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
case "$*" in *" 10 "*) echo "VERDICT: LANDED (exit 4)";; *) echo "VERDICT: CLEAN";; esac
PY
  chmod +x "$RC2/fakesc/.venv/bin/python"
  O="$RC2" LIMIT=1 SC="$RC2/fakesc" PY="$RC2/fakesc/.venv/bin/python" PREFLIGHT="$RC2/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" > "$TMP/landed-cap-1.out" 2>&1
  case "$(tr '\n' ' ' < "$RC2/landed.txt")" in *10*) rc=0;; *) rc=1;; esac
  ck "shipped refresh loop: the LANDED entry is recorded while the slot is spent" $rc
  [ "$(tr '\n' ' ' < "$RC2/candidates.txt" | wc -w | tr -d ' ')" = "0" ] && rc=0 || rc=1
  ck "shipped refresh loop: the LIMIT-1 pass pre-flights one issue and queues none of them" $rc
  O="$RC2" LIMIT=1 SC="$RC2/fakesc" PY="$RC2/fakesc/.venv/bin/python" PREFLIGHT="$RC2/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" > "$TMP/landed-cap-2.out" 2>&1
  case "$(tr '\n' ' ' < "$RC2/candidates.txt")" in *20*) rc=0;; *) rc=1;; esac
  ck "shipped refresh loop: a recorded LANDED entry frees the next pass's LIMIT slot (20 queued)" $rc

  # ── 5h) a persistently non-answering entry is retried, then BOUNDED (tortoise#8469 P2) ────────
  # Without a bound the cursor can never advance past a pool head that never answers, so the entries
  # behind it starve forever. RETRY_MAX verdict-less attempts mark it checked and name the attempt.
  RL3="$TMP/retry"; mkdir -p "$RL3/fakesc/.venv/bin"
  printf '10\n' > "$RL3/.pool"
  : > "$RL3/checked.txt"; : > "$RL3/candidates.txt"; : > "$RL3/dispatched.txt"; : > "$RL3/landed.txt"
  cat > "$RL3/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
# a pre-flight that never answers: no VERDICT line, non-3 exit (3 is the provisioning refusal)
echo 'boom: no verdict' >&2; exit 1
PY
  chmod +x "$RL3/fakesc/.venv/bin/python"
  O="$RL3" LIMIT=2 RETRY_MAX=3 SC="$RL3/fakesc" PY="$RL3/fakesc/.venv/bin/python" PREFLIGHT="$RL3/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" > "$TMP/retry-1.out" 2>&1
  # attempt 1 must NOT blacklist it: a transient failure is recoverable
  if grep -q 'attempt 1/3' "$TMP/retry-1.out" && ! grep -qx 10 "$RL3/checked.txt"; then rc=0; else rc=1; fi
  ck "shipped refresh loop: a failed pre-flight is retried, not blacklisted on attempt 1" $rc
  for _pass in 2 3; do
    O="$RL3" LIMIT=2 RETRY_MAX=3 SC="$RL3/fakesc" PY="$RL3/fakesc/.venv/bin/python" PREFLIGHT="$RL3/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" > "$TMP/retry.out" 2>&1
  done
  if grep -q 'marked checked after 3 verdict-less attempts' "$TMP/retry.out" && [ "$(tr '\n' ' ' < "$RL3/checked.txt")" = "10 " ]; then rc=0; else rc=1; fi
  ck "shipped refresh loop: a persistently non-verdict entry is retried then bounded (RETRY_MAX)" $rc

  # ── 5h-bis) a PRE-FLIGHT `INCOMPLETE` IS NOT A STRIKE (review P1) ──────────────────────────────
  # The port folded the box-wide `INCOMPLETE` (a surface could not be queried) into the RETRY_MAX arm,
  # so on an outage three passes appended the WHOLE walked pool to checked.txt — permanent, because
  # only numbers that later reach dispatched.txt are ever reclaimed. A box-wide outage then reads as an
  # empty backlog and nothing dispatches. The state was measured live on the fleet box before this
  # fork was retired (`checked.txt: 310` while every candidate's verdict was INCOMPLETE —
  # refresh-scout.test.sh's cmux case records that same reading). It must stay VISIBLE every pass and
  # never be checked off.
  RV2="$TMP/inc"; mkdir -p "$RV2/fakesc/.venv/bin"
  printf '10\n20\n' > "$RV2/.pool"
  : > "$RV2/checked.txt"; : > "$RV2/candidates.txt"; : > "$RV2/dispatched.txt"; : > "$RV2/landed.txt"
  cat > "$RV2/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
# a pre-flight on a box-wide outage: it answers, and the answer is "could not query a surface"
echo 'SURFACE  issue assignee/holder  INCOMPLETE  0  the board could not be read'
echo 'VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried; NOT clean'
exit 2
PY
  chmod +x "$RV2/fakesc/.venv/bin/python"
  for _pass in 1 2 3 4 5; do
    O="$RV2" LIMIT=2 RETRY_MAX=2 SC="$RV2/fakesc" PY="$RV2/fakesc/.venv/bin/python" PREFLIGHT="$RV2/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" > "$TMP/inc.out" 2>&1
  done
  if [ ! -s "$RV2/checked.txt" ] && [ ! -s "$RV2/candidates.txt" ] && grep -q 'INCOMPLETE' "$TMP/inc.out"; then rc=0; else
    rc=1; echo "      checked=[$(tr '\n' ' ' < "$RV2/checked.txt")] candidates=[$(tr '\n' ' ' < "$RV2/candidates.txt")]"
  fi
  ck "shipped refresh loop: a pre-flight INCOMPLETE is re-visible every pass and never checked off" $rc
  # ⛔ THE COUNTER BELONGS TO THE VERDICT-LESS ARM ALONE (review P1, final round — the defect this
  # block now pins in BOTH directions). Round 4 spanned both kinds under one counter and gated
  # retirement on a `pretryown-<N>` marker, which made the box-wide passes SUPPLY the count: at the
  # default RETRY_MAX=3 the sequence `INCOMPLETE`, `INCOMPLETE`, verdict-less retired an OPEN issue to
  # checked.txt — permanent, invisible, never dispatched — on the candidate's FIRST own failure. The
  # sequences below are that report, verbatim.
  vlessf() { printf '#!/bin/bash\necho "boom: no verdict" >&2; exit 1\n' > "$1/fakesc/.venv/bin/python"; chmod +x "$1/fakesc/.venv/bin/python"; }
  incptf() { printf '#!/bin/bash\necho "VERDICT: INCOMPLETE (exit 2) - 1 surface(s) could not be queried; NOT clean"\nexit 2\n' > "$1/fakesc/.venv/bin/python"; chmod +x "$1/fakesc/.venv/bin/python"; }
  # ploopf <dir> <retry_max> <out>: one pass of the SHIPPED loop against that fixture
  ploopf() { O="$1" LIMIT=2 RETRY_MAX="$2" SC="$1/fakesc" PY="$1/fakesc/.venv/bin/python" PREFLIGHT="$1/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-drive.sh" >> "$3" 2>&1; }
  RV3="$TMP/inc-mixed3"; mkdir -p "$RV3/fakesc/.venv/bin"
  printf '10\n20\n' > "$RV3/.pool"
  : > "$RV3/checked.txt"; : > "$RV3/candidates.txt"; : > "$RV3/dispatched.txt"; : > "$RV3/landed.txt"
  : > "$TMP/inc3.out"
  incptf "$RV3"; ploopf "$RV3" 3 "$TMP/inc3.out"
  incptf "$RV3"; ploopf "$RV3" 3 "$TMP/inc3.out"
  vlessf "$RV3"; ploopf "$RV3" 3 "$TMP/inc3.out"
  if [ ! -s "$RV3/checked.txt" ]; then rc=0; else
    rc=1; echo "      two box-wide outages + ONE verdict-less run retired: checked=[$(tr '\n' ' ' < "$RV3/checked.txt")]"
  fi
  ck "shipped refresh loop: outage passes cannot SUPPLY the count for one later verdict-less run (INCOMPLETE x2 then verdict-less, RETRY_MAX=3)" $rc
  : > "$RV3/checked.txt"; rm -rf "$RV3/state"
  vlessf "$RV3"; ploopf "$RV3" 3 "$TMP/inc3.out"
  incptf "$RV3"; ploopf "$RV3" 3 "$TMP/inc3.out"
  incptf "$RV3"; ploopf "$RV3" 3 "$TMP/inc3.out"
  if [ ! -s "$RV3/checked.txt" ]; then rc=0; else
    rc=1; echo "      verdict-less then two outages retired: checked=[$(tr '\n' ' ' < "$RV3/checked.txt")]"
  fi
  ck "shipped refresh loop: outage passes cannot CARRY a verdict-less run to the bound (verdict-less then INCOMPLETE x2, RETRY_MAX=3)" $rc
  # …and a MIXED chain that really does collect RETRY_MAX runs of its OWN failure must still be
  # BOUNDED, or a pool head that never answers starves every entry behind it (the #8469 defect the
  # bound exists for). Counted in verdict-less runs, an alternating chain retires at 2*RETRY_MAX
  # passes; counting it in BOTH kinds is what made an outage count, so this is the bound's remaining
  # proof: the outage passes neither advance nor reset it.
  : > "$RV2/checked.txt"; rm -rf "$RV2/state"; : > "$TMP/inc2.out"
  vlessf "$RV2"; ploopf "$RV2" 2 "$TMP/inc2.out"
  incptf "$RV2"; ploopf "$RV2" 2 "$TMP/inc2.out"
  if [ ! -s "$RV2/checked.txt" ]; then rc=0; else
    rc=1; echo "      one verdict-less run + an outage retired at RETRY_MAX=2: checked=[$(tr '\n' ' ' < "$RV2/checked.txt")]"
  fi
  ck "shipped refresh loop: an INCOMPLETE does not count as a strike (verdict-less then INCOMPLETE, RETRY_MAX=2)" $rc
  vlessf "$RV2"; ploopf "$RV2" 2 "$TMP/inc2.out"
  incptf "$RV2"; ploopf "$RV2" 2 "$TMP/inc2.out"
  case "$(tr '\n' ' ' < "$RV2/checked.txt")" in *10*20*) rc=0;; *) rc=1;; esac
  if [ "$rc" -ne 0 ]; then echo "      a MIXED non-answer chain never retired: checked=[$(tr '\n' ' ' < "$RV2/checked.txt")] after 2 own failures (starvation)"; fi
  ck "shipped refresh loop: an ALTERNATING verdict-less/INCOMPLETE chain IS bounded (retires at RETRY_MAX own failures)" $rc
  # …and the SAME sequence WITHOUT any verdict-less run must never retire: a pure box-wide outage is
  # re-visible every pass, however long it lasts (this is the P1 that started the arm split).
  : > "$RV2/checked.txt"; rm -rf "$RV2/state"
  incptf "$RV2"; ploopf "$RV2" 2 "$TMP/inc2.out"
  incptf "$RV2"; ploopf "$RV2" 2 "$TMP/inc2.out"
  incptf "$RV2"; ploopf "$RV2" 2 "$TMP/inc2.out"
  if [ ! -s "$RV2/checked.txt" ]; then rc=0; else
    rc=1; echo "      a PURE outage retired entries: checked=[$(tr '\n' ' ' < "$RV2/checked.txt")]"
  fi
  ck "shipped refresh loop: a PURE box-wide outage is never retired, however long it lasts" $rc
  # …AND THAT HOLDS AFTER A RETIREMENT HAS HAPPENED (review P2, round 5). Round 4's verdict-less
  # retirement left `pretryown-<N>` behind, and `checked.txt` is reclaimable — so once the entry came
  # back, a PURE outage met the stale marker and retired it. The marker is gone; the sequence is kept
  # as the regression that a consumed counter cannot outlive its retirement.
  : > "$RV2/checked.txt"; rm -rf "$RV2/state"
  vlessf "$RV2"; ploopf "$RV2" 2 "$TMP/inc2.out"
  vlessf "$RV2"; ploopf "$RV2" 2 "$TMP/inc2.out"
  : > "$RV2/checked.txt"   # the only recovery for a wrongly-blacklisted entry
  incptf "$RV2"; ploopf "$RV2" 2 "$TMP/inc2.out"
  incptf "$RV2"; ploopf "$RV2" 2 "$TMP/inc2.out"
  if [ ! -s "$RV2/checked.txt" ]; then rc=0; else
    rc=1; echo "      a stale strike marker retired a PURE outage: checked=[$(tr '\n' ' ' < "$RV2/checked.txt")]"
  fi
  ck "shipped refresh loop: a stale strike marker must not retire a later PURE outage" $rc
fi

# ── 5i) the reaper SETTLES a landed entry: CLOSED dropped, OPEN released, unreadable kept ────
# landed.txt must not become the permanent list checked.txt was. An entry means "a decision is
# owed"; once the issue is CLOSED it is made. Fail-closed still applies: an entry whose state
# cannot be READ is kept, never assumed closed.
# ⛔ THE PRUNE READS `gh issue view <N> --json state` (UNCAPPED), NOT absence from `.open_iss`:
# `.open_iss` is `--limit 500` against a repo with >500 open issues, so it is permanently
# saturated and absence from it proves nothing.
if need "$R/reap.py" "the reaper is extracted from the shipped refresh-candidates.sh (landed prune)"; then
  RP="$TMP/landed-prune"; mkdir -p "$RP"
  printf '10\n30\n' > "$RP/landed.txt"
  : > "$RP/.open_iss"; : > "$RP/.pr_brs"
  : > "$RP/dispatched.txt"; : > "$RP/checked.txt"
  ( PATH="$R:$PATH" GH_STUB_OPEN="10" python3 "$R/reap.py" "$RP" "acme/example" ) > "$TMP/landed-prune.out" 2>&1
  case "$(tr '\n' ' ' < "$RP/landed.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "shipped reaper: a landed entry whose issue is still OPEN is RELEASED" $rc
  case "$(tr '\n' ' ' < "$RP/landed.txt")" in *30*) rc=1;; *) rc=0;; esac
  ck "shipped reaper: a landed entry whose issue is CLOSED is dropped" $rc
  case "$(cat "$TMP/landed-prune.out")" in *"dropped"*30*) rc=0;; *) rc=1;; esac
  ck "shipped reaper: dropping a settled landed entry is logged, not silent" $rc
  case "$(cat "$TMP/landed-prune.out")" in *"OPEN — RELEASED"*10*) rc=0;; *) rc=1;; esac
  ck "shipped reaper: releasing an OPEN landed entry is logged" $rc
  # fail-closed half: an UNREADABLE state prunes NOTHING (a failed read is not "closed")
  RPF="$TMP/landed-prune-fail"; mkdir -p "$RPF"
  printf '10\n30\n' > "$RPF/landed.txt"
  : > "$RPF/.open_iss"; : > "$RPF/.pr_brs"
  : > "$RPF/dispatched.txt"; : > "$RPF/checked.txt"
  ( PATH="$R:$PATH" GH_STUB_FAIL=1 python3 "$R/reap.py" "$RPF" "acme/example" ) > "$TMP/landed-prune-fail.out" 2>&1
  case "$(tr '\n' ' ' < "$RPF/landed.txt")" in *10*30*) rc=0;; *) rc=1;; esac
  ck "shipped reaper: an UNREADABLE landed state prunes no entry (both kept)" $rc
  case "$(cat "$TMP/landed-prune-fail.out")" in *"could not be re-read"*) rc=0;; *) rc=1;; esac
  ck "shipped reaper: keeping an unreadable landed entry is logged, not silent" $rc
  # ⛔ NON-VACUOUS against the pre-fix cap guard: `.open_iss` is SATURATED at 500 entries and omits
  # 10, while gh reports 10 OPEN. Absence from a capped listing proves nothing, so the targeted read
  # must answer OPEN for 10 — released — and 30 (CLOSED) must still be dropped.
  RPT="$TMP/landed-prune-saturated"; mkdir -p "$RPT"
  printf '10\n30\n' > "$RPT/landed.txt"
  seq 1 500 | grep -v '^10$' | grep -v '^30$' > "$RPT/.open_iss"
  : > "$RPT/.pr_brs"
  : > "$RPT/dispatched.txt"; : > "$RPT/checked.txt"
  ( PATH="$R:$PATH" GH_STUB_OPEN="10" python3 "$R/reap.py" "$RPT" "acme/example" ) > "$TMP/landed-prune-sat.out" 2>&1
  case "$(tr '\n' ' ' < "$RPT/landed.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "shipped reaper: a saturated .open_iss does NOT mask the targeted OPEN read — 10 is RELEASED" $rc
  case "$(tr '\n' ' ' < "$RPT/landed.txt")" in *30*) rc=1;; *) rc=0;; esac
  ck "shipped reaper: the landed prune settles a CLOSED entry even when .open_iss is saturated" $rc
  # ── 5j) a HOLDER-ONLY INCOMPLETE is decided by the CROSS-BOX claim registry (#1935) ─────────
  # The live cloud cell's pre-flight returns nothing else: its fleet board cannot answer (no cmux
  # lane registry, and this cmux flavor has no `sessions list`), so every candidate was INCOMPLETE
  # and the backlog stayed 0 all evening. The tool's own arithmetic makes a holder-only INCOMPLETE a
  # statement that every surface it COULD read was clean, so the holder question falls to the
  # cross-box registry. Three arms: the answer is a claim (queue), it is unreadable (refuse), or
  # another surface is ALSO unreadable (refuse — the tool could not judge the WORK).
  HI="$TMP/holderinc"; mkdir -p "$HI/fakesc/.venv/bin"
  printf '10\n' > "$HI/.pool"
  : > "$HI/checked.txt"; : > "$HI/candidates.txt"; : > "$HI/dispatched.txt"
  # The registry FILE the real reader sources; the READER function is supplied only in arm (ii), so
  # arm (i) pins the "file present, function absent" shape the extraction really has.
  : > "$HI/claims.sh"
  cat > "$HI/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
# the live cell's actual answer: every other surface clean, the BOARD unable to say who holds it
cat <<'REPORT'
collision-preflight: issue #10
issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer — the board's live-session store could not be read

INCOMPLETE SURFACES
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer — the board's live-session store could not be read, so NO lane's liveness is measurable

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried (issue assignee/holder); this is NOT clean for #10 in acme/widget
REPORT
exit 2
PY
  chmod +x "$HI/fakesc/.venv/bin/python"
  # (i) NO CLAIM READER IN THE EXTRACTION. The extracted body carries no `issue_claim_verdict`, so the
  # call returns 127 — an UNRECOGNISED code, which must land in the `case`'s `*)` arm and be
  # INCOMPLETE. ⛔ THIS ARM USED TO ASSERT ONLY "#10 is absent from candidates.txt", WHICH PASSES ON
  # ANY CODE THAT REFUSES — including the pre-fix (no re-route at all) and including the extraction's
  # `$O/claims.sh` file being absent, i.e. it could not distinguish the `*)` arm from a no-op. It also
  # carried a false premise ("127 … therefore QUEUES" — the `*)` arm forbids exactly that) that the
  # removed guard rested on (review F1). So the arm now names the arm that MUST have produced the
  # refusal (`UNRECOGNISED verdict (rc=127)`) as well as the outcome, and a body whose `*)` arm queued
  # would redden both assertions.
  O="$HI" LIMIT=5 SC="$HI/fakesc" PY="$HI/fakesc/.venv/bin/python" PREFLIGHT="$HI/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop.sh" > "$TMP/holderinc-none.out" 2>&1
  case "$(tr '\n' ' ' < "$HI/candidates.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "holder-only INCOMPLETE with NO claim reader available is NOT queued (127 is not CLEAN)" $rc
  case "$(cat "$TMP/holderinc-none.out")" in
    *"UNRECOGNISED verdict (rc=127)"*) rc=0;;
    *) rc=1; echo "      out: $(grep -F '#10' "$TMP/holderinc-none.out" | head -3)";;
  esac
  ck "…and it is the *) UNRECOGNISED-verdict arm that refused it (the arm this case is named for)" $rc
  # (ii) the registry ANSWERS: a stub reader returns 0, supplied the way the shipped script has it at
  # top level — prepended to the extraction, so the real arm is what runs.
  { printf 'issue_claim_verdict() { CLAIM_RESULT="stub: no claim"; return 0; }\n'; cat "$TMP/refreshloop.sh"; } > "$TMP/refreshloop-claim.sh"
  O="$HI" LIMIT=5 SC="$HI/fakesc" PY="$HI/fakesc/.venv/bin/python" PREFLIGHT="$HI/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-claim.sh" > "$TMP/holderinc-claim.out" 2>&1
  case "$(tr '\n' ' ' < "$HI/candidates.txt")" in *10*) rc=0;; *) rc=1;; esac
  ck "holder-only INCOMPLETE: the cross-box registry's CLEAN verdict queues the candidate" $rc
  case "$(tr '\n' ' ' < "$HI/checked.txt")" in *10*) rc=0;; *) rc=1;; esac
  ck "holder-only INCOMPLETE queued via the registry is also marked checked" $rc
  # (ii-b) the registry is NOT INSTALLED: nothing has answered the holder question, so refuse. This is
  # the arm that keeps the re-route from becoming "no registry, so nobody holds it".
  mv "$HI/claims.sh" "$HI/claims.sh.away"
  : > "$HI/candidates.txt"; : > "$HI/checked.txt"
  O="$HI" LIMIT=5 SC="$HI/fakesc" PY="$HI/fakesc/.venv/bin/python" PREFLIGHT="$HI/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-claim.sh" > "$TMP/holderinc-noreg.out" 2>&1
  case "$(tr '\n' ' ' < "$HI/candidates.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "holder-only INCOMPLETE with NO claim registry on the box is NOT queued" $rc
  mv "$HI/claims.sh.away" "$HI/claims.sh"
  # (iii) a SECOND unreadable surface means the tool could not judge the work: no re-route.
  HI2="$TMP/holderinc2"; mkdir -p "$HI2/fakesc/.venv/bin"
  printf '10\n' > "$HI2/.pool"
  : > "$HI2/checked.txt"; : > "$HI2/candidates.txt"; : > "$HI2/dispatched.txt"
  cat > "$HI2/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
cat <<'REPORT'
open PRs                        INCOMPLETE  0     gh: could not reach api.github.com
issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer

INCOMPLETE SURFACES
  [open PRs] gh: could not reach api.github.com
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer

VERDICT: INCOMPLETE (exit 2) — 2 surface(s) could not be queried (open PRs, issue assignee/holder)
REPORT
exit 2
PY
  chmod +x "$HI2/fakesc/.venv/bin/python"
  O="$HI2" LIMIT=5 SC="$HI2/fakesc" PY="$HI2/fakesc/.venv/bin/python" PREFLIGHT="$HI2/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-claim.sh" > "$TMP/holderinc-multi.out" 2>&1
  case "$(tr '\n' ' ' < "$HI2/candidates.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "an INCOMPLETE with ANOTHER unreadable surface is NOT re-routed (the work itself is unjudged)" $rc

  # ── 5k) the re-route's own safety properties, on the path where it FIRES ────────────────────
  # Each arm reuses the fixture (holder-only report + a stub reader) and varies only what the
  # registry ANSWERS. What is asserted every time is that a peer's work is never dispatched.
  holder_arm() { # <name> <reader-body>  → runs the loop with that reader, prints nothing
    { printf 'issue_claim_verdict() { CLAIM_RESULT="stub"; %s\n}\n' "$2"; cat "$TMP/refreshloop.sh"; } > "$TMP/refreshloop-h.sh"
    : > "$HI/candidates.txt"; : > "$HI/checked.txt"
    O="$HI" LIMIT=5 SC="$HI/fakesc" PY="$HI/fakesc/.venv/bin/python" PREFLIGHT="$HI/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-h.sh" > "$TMP/holder-$1.out" 2>&1
  }
  # (a) A LIVE CLAIM is the primary thing this gate exists to catch: registry rc=1 must never queue.
  holder_arm live 'return 1'
  case "$(tr '\n' ' ' < "$HI/candidates.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "holder-only INCOMPLETE + a LIVE claim: NOT queued (the registry's refusal is honoured)" $rc
  case "$(tr '\n' ' ' < "$HI/checked.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "holder-only INCOMPLETE + a LIVE claim: NOT marked checked (re-attempted next pass)" $rc
  # (b) A STALE READER (rc=3, a claims.sh predating the issue reader) is a permanent local refusal.
  holder_arm stale 'return 3'
  case "$(tr '\n' ' ' < "$HI/candidates.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "holder-only INCOMPLETE + a STALE claim reader (rc=3): NOT queued" $rc
  # (c) F1's fail-OPEN (found in review): the SAME surface is also marked INCOMPLETE when the board
  # DID answer and ATTRIBUTED a lane whose liveness it could not measure. The claim registry would
  # then say CLEAN for a lane that never took a claim (or whose lease expired), so the name alone
  # must NOT re-route — the whole-board wording is part of the condition.
  H3="$TMP/holderinc3"; mkdir -p "$H3/fakesc/.venv/bin"
  printf '10\n' > "$H3/.pool"; : > "$H3/checked.txt"; : > "$H3/candidates.txt"; : > "$H3/dispatched.txt"
  : > "$H3/claims.sh"
  cat > "$H3/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
cat <<'REPORT'
issue assignee/holder           INCOMPLETE  0     claim gate: holder read from the FLEET BOARD (source: cache) — 1 lane(s) attributed, but its pid_alive is UNMEASURED

INCOMPLETE SURFACES
  [issue assignee/holder] claim gate: holder read from the FLEET BOARD (source: cache) — 1 lane(s) attributed to #10, and no pid reading exists for it

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried (issue assignee/holder)
REPORT
exit 2
PY
  chmod +x "$H3/fakesc/.venv/bin/python"
  { printf 'issue_claim_verdict() { CLAIM_RESULT="stub: no claim"; return 0; }\n'; cat "$TMP/refreshloop.sh"; } > "$TMP/refreshloop-h3.sh"
  O="$H3" LIMIT=5 SC="$H3/fakesc" PY="$H3/fakesc/.venv/bin/python" PREFLIGHT="$H3/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-h3.sh" > "$TMP/holder-partial.out" 2>&1
  case "$(tr '\n' ' ' < "$H3/candidates.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "a PARTIAL board answer (a lane IS attributed) is NOT re-routed — a claimless lane is not a free issue" $rc
  # (d) FORMAT DRIFT: an INCOMPLETE verdict with NO surface section at all must refuse, never re-route.
  H4="$TMP/holderinc4"; mkdir -p "$H4/fakesc/.venv/bin"
  printf '10\n' > "$H4/.pool"; : > "$H4/checked.txt"; : > "$H4/candidates.txt"; : > "$H4/dispatched.txt"
  : > "$H4/claims.sh"
  cat > "$H4/fakesc/.venv/bin/python" <<'PY'
#!/bin/bash
# a FUTURE producer that reworded the section away: the verdict is still INCOMPLETE
printf 'VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried\n'
exit 2
PY
  chmod +x "$H4/fakesc/.venv/bin/python"
  O="$H4" LIMIT=5 SC="$H4/fakesc" PY="$H4/fakesc/.venv/bin/python" PREFLIGHT="$H4/fakesc/tools/collision_preflight.py" bash "$TMP/refreshloop-h3.sh" > "$TMP/holder-nosection.out" 2>&1
  case "$(tr '\n' ' ' < "$H4/candidates.txt")" in *10*) rc=1;; *) rc=0;; esac
  ck "an INCOMPLETE with NO surface section (format drift) is NOT re-routed" $rc

  # ── 5l) the surface SET is read from the VERDICT LINE, and a report carrying a BLOCKING hit is
  # not a verdict at all (cycle-2 review, F1 + F2 — both reproduced fail-OPENs before these arms).
  # The producer is resolved from the TARGET repo, so it DRIFTS; these are the shapes that would
  # have queued a candidate the same producer's own table calls blocked or unjudged.
  holder_report() { # <outfile> <report-body>  → a fixture whose stub prints that body for issue 10
    local d; d="$(mktemp -d "$TMP/hrep.XXXXXX")"; mkdir -p "$d/fakesc/.venv/bin"
    printf '10\n' > "$d/.pool"; : > "$d/checked.txt"; : > "$d/candidates.txt"; : > "$d/dispatched.txt"; : > "$d/claims.sh"
    { printf '#!/bin/bash\ncat <<\x27REPORT\x27\n'; printf '%s\n' "$2"; printf 'REPORT\nexit 2\n'; } > "$d/fakesc/.venv/bin/python"
    chmod +x "$d/fakesc/.venv/bin/python"; printf '%s' "$d"
  }
  holder_run() { # <dir> [outfile-suffix]
    O="$1" LIMIT=5 SC="$1/fakesc" PY="$1/fakesc/.venv/bin/python" PREFLIGHT="$1/fakesc/tools/collision_preflight.py" \
      bash "$TMP/refreshloop-claim.sh" > "$TMP/holder-$2.out" 2>&1
  }
  holder_queued() { case "$(tr '\n' ' ' < "$1/candidates.txt")" in *10*) echo 1;; *) echo 0;; esac; }  # 1 = queued = FAIL code

  # (f1) A BLOCKING HIT alongside an INCOMPLETE verdict. The re-route trusts the producer's verdict
  # ORDER; this report is self-contradicting (the class the DEGRADED read already exists for, #1853),
  # and its own table says COLLISION. An advisory hit must NOT trip this arm — hence the second case.
  D5="$(holder_report x 'open PRs                        COLLISION   1     matched issue-number (10) in title, OPEN (number)
issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer

HITS
  [open PRs] #12 — matched issue-number (10) in title, OPEN (number)

INCOMPLETE SURFACES
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried (issue assignee/holder)')"
  holder_run "$D5" f1; ck "an INCOMPLETE verdict carrying a BLOCKING hit is NOT queued (a self-contradicting report is not a verdict)" "$(holder_queued "$D5")"
  # …and ADVISORY hits, which also print under HITS, must keep the re-route alive: the arm above is
  # about a BLOCKING tag, not about "any hit at all" (the producer appends ` (advisory — cannot
  # block)` AFTER the strength tag, so an advisory line does not END with it).
  D6="$(holder_report x 'open PRs                        ADVISORY    1     matched issue-number (10) in title, MERGED (weak) (advisory — cannot block)
issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer

HITS
  [open PRs] #11 — matched issue-number (10) in title, MERGED (weak) (advisory — cannot block)

INCOMPLETE SURFACES
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried (issue assignee/holder)')"
  holder_run "$D6" f1b
  if [ "$(holder_queued "$D6")" = 1 ]; then ck "an ADVISORY hit does NOT block the re-route (the condition is the blocking tag, not any hit)" 0; else ck "an ADVISORY hit does NOT block the re-route (the condition is the blocking tag, not any hit)" 1; fi
  # (f0) THE GREPS MUST SEE THE WHOLE REPORT — the SIGPIPE window (#841/#864). `printf | grep -q` is
  # refused repo-wide by scripts/check-no-sigpipe-grep.sh (the PR-lane job `sigpipe-grep`), and this is
  # the FAIL-OPEN it buys: with `pipefail` active the quiet grep exits at its FIRST match while the
  # writer is still pushing, the writer takes SIGPIPE (141), pipefail reports the PIPELINE red — and
  # `hits_blocking` stays 0. A report that states BOTH a blocking hit AND a holder-only INCOMPLETE is
  # then re-routed as holder-only and QUEUED, which is the duplicate-dispatch class this block exists
  # to refuse. The payload matters: the match must be EARLY and the body >64 KiB (the pipe buffer), or
  # grep reads everything and the race never fires — a short-payload arm here would be vacuous. Run
  # the loop under `bash -o pipefail`: the shipped script sets `set -u` ONLY, so the window is LATENT
  # today rather than live — which is precisely why the guard bans the SHAPE instead of arguing about
  # this one site, and why the fix is a here-string (no writer left to kill) rather than a trade.
  FILLER="$(i=0; while [ "$i" -lt 2000 ]; do i=$((i + 1)); printf 'filler line %s pushing the report past the 64 KiB pipe buffer\n' "$i"; done)"
  # SELF-CONTRADICTING and LARGE: the blocking hit is on line 2 (EARLY, so the quiet grep can exit
  # while the writer still has ~64 KiB queued) and the holder note is the LAST line (so the second
  # grep reads everything and does not race). That asymmetry is what separates the two outcomes on the
  # pre-fix code: the blocking grep reads FALSE, the note grep reads TRUE, and the candidate is queued.
  D4="$(holder_report x "open PRs                        COLLISION   1     matched issue-number (10) in title, OPEN (number)
HITS
  [open PRs] #12 — matched issue-number (10) in title, OPEN (number)
issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer
$FILLER

INCOMPLETE SURFACES
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried (issue assignee/holder)")"
  # same extraction, invoked with the pipefail the race needs
  O="$D4" LIMIT=5 SC="$D4/fakesc" PY="$D4/fakesc/.venv/bin/python" PREFLIGHT="$D4/fakesc/tools/collision_preflight.py" \
    bash -o pipefail "$TMP/refreshloop-claim.sh" > "$TMP/holder-f0.out" 2>&1
  ck "a >64 KiB self-contradicting report is NOT queued under pipefail (the greps are not a pipeline)" "$(holder_queued "$D4")"
  # …and the SAME SIZE of report WITHOUT a blocking hit still re-routes, so the arm above cannot pass
  # by refusing every large report (a fail-closed arm alone proves nothing about the fail-open).
  D4B="$(holder_report x "issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer
$FILLER

INCOMPLETE SURFACES
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried (issue assignee/holder)")"
  O="$D4B" LIMIT=5 SC="$D4B/fakesc" PY="$D4B/fakesc/.venv/bin/python" PREFLIGHT="$D4B/fakesc/tools/collision_preflight.py" \
    bash -o pipefail "$TMP/refreshloop-claim.sh" > "$TMP/holder-f0b.out" 2>&1
  if [ "$(holder_queued "$D4B")" = 1 ]; then ck "…and a >64 KiB HOLDER-ONLY report IS still re-routed under pipefail (no false block)" 0; else ck "…and a >64 KiB HOLDER-ONLY report IS still re-routed under pipefail (no false block)" 1; fi
  # (f2) The COUNT now comes from the verdict line, so a body whose section was truncated by a
  # multi-line note (or reordered) can no longer turn "2 unreadable surfaces" into "1".
  D7="$(holder_report x 'issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer
this note continued at column 0 — the old section parse ENDED here
open PRs                        INCOMPLETE  0     gh: could not reach api.github.com

INCOMPLETE SURFACES
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer
this note continued at column 0 — the old section parse ENDED here
  [open PRs] gh: could not reach api.github.com

VERDICT: INCOMPLETE (exit 2) — 2 surface(s) could not be queried (issue assignee/holder, open PRs)')"
  holder_run "$D7" f2; ck "a SECOND unreadable surface is still refused when the holder note wraps (the count is the verdict line's, not a parsed section)" "$(holder_queued "$D7")"
  # (f3) A2 ANCHORING: the report echoes the issue TITLE. A title carrying the section heading and an
  # indented holder line must not MANUFACTURE a holder-only answer — the verdict line says the
  # unreadable surface is `open PRs`, so nothing may be re-routed on the strength of the echo.
  D8="$(holder_report x 'title: fake (10) INCOMPLETE SURFACES
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer
open PRs                        INCOMPLETE  0     gh: could not reach api.github.com

INCOMPLETE SURFACES
  [open PRs] gh: could not reach api.github.com

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried (open PRs)')"
  holder_run "$D8" f3; ck "a title echo cannot forge a holder-only INCOMPLETE (the verdict line is the answer, the body is not)" "$(holder_queued "$D8")"
  # (f4) A SURFACE-TABLE-ONLY REPORT — NO `INCOMPLETE SURFACES` BLOCK (#1977 review, P2). The producer
  # emits both shapes (see `mk_tool_incomplete … table` in origination-funnel.test.sh) and the measured
  # cell output quoted in #1935 is this one, yet every fixture here carried the block — so the block-row
  # grep read TRUE in the suite and FALSE on the live cell, and the headline fix was a no-op there
  # (fail-closed, so silent). The row is read through `preflight_unusable_surfaces`, which handles both
  # shapes; this arm is what makes that a requirement instead of an accident.
  D9="$(holder_report x 'issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer — the board live-session store could not be read

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be queried (issue assignee/holder)')"
  holder_run "$D9" f4
  if [ "$(holder_queued "$D9")" = 1 ]; then ck "a TABLE-ONLY holder report (no INCOMPLETE SURFACES block) IS re-routed — the shape the live cell emits" 0; else ck "a TABLE-ONLY holder report (no INCOMPLETE SURFACES block) IS re-routed — the shape the live cell emits" 1; fi

  # ── 5l-bis) THE PRODUCER'S WORDING IS NOT PART OF THE CONTRACT (agent-infra#2952) ──────────────
  # THE DEFECT, MEASURED. The surface set was read with the literal phrase `could not be queried (`.
  # tortoise fa7b27b66 (#9423, 2026-10-21) reworded that sentence to `could not be FULLY queried (`,
  # and from that commit the parse returned an EMPTY set for EVERY verdict — so `HOLDER_ONLY` was 0
  # for every candidate, the #1935 substitution above could never fire, and cell4 spent six days
  # reporting `0 dispatched` / `unusable=issue-assignee-holder:12` while THIS SUITE stayed green,
  # because every fixture above still rendered the wording shipped on the day it was written. A test
  # that only ever replays yesterday's wording cannot fail for a producer reword — which is exactly
  # the "guard that cannot fail" this arm exists to remove. So these arms render the producer's REAL
  # line, and one of them renders an adverb it has never used, to pin the CONTRACT ("the surfaces are
  # named in the parenthetical after `queried (`") instead of a phrase of the day.
  #
  # The body below is cell4's own report for #9889, copied VERBATIM (the board note is abridged in its
  # middle, marked `…`) from `python3 tools/collision_preflight.py 9889 --repo .` on the cell's own
  # checkout, 2026-10-27. It is the shape that MUST be re-routed: ONE unreadable surface, the fleet
  # board, every other surface clean.
  # ⛔ THE REPORT IS WRITTEN TO A FILE, NOT CAPTURED THROUGH `$(cat <<'REPORT' …)`: bash 3.2 (macOS's
  # /bin/bash, the shell this suite gets via `env bash` on a stock runner) quote-scans the body of a
  # heredoc that lives inside a command substitution, so a line with ONE apostrophe (`the board's …`)
  # aborts the WHOLE suite with `unexpected EOF while looking for matching` — measured here, and the
  # real report has three such lines. A plain `cat > file <<'REPORT'` is not scanned, and the variable
  # is then filled from the file.
  cat > "$TMP/cell2952.report" <<'REPORT'
collision-preflight: issue #9889
repo: daniel-ospina/tortoise   [resolved from: --repo PATH (git remote)]

title: measure(extractor-v4): E1's before arm and E2a's 14-unit denominator are producible
keyword gate: none — the lexical arm is deleted (#3504).

SURFACE                         STATUS      HITS  NOTE
issue landed                    CLEAN       0     issue state=OPEN; 7 timeline event(s), 1 merged cross-reference(s), none naming #9889 in its title
merged PRs naming an OPEN issue ADVISORY    0
open PRs                        CLEAN       0     25 PR(s) enumerated (complete, cap 1000)
recently-closed PRs             ADVISORY    1     ⚠ PARTIAL — advisory sample, cannot block
local branches                  CLEAN       0     17 ref(s) enumerated; 2 already merged into main
remote branches                 CLEAN       0     1858 ref(s) enumerated
local worktrees                 CLEAN       0     15 worktree(s) enumerated (untruncated)
issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer — the board's lane registry could not be read (FileNotFoundError: [Errno 2] No such file or directory: '/home/cmux/.pi/agent/state/lane-registry.tsv') — the lane roster is UNKNOWN, not empty … (comment prose is not read, #8175)

HITS
  [recently-closed PRs] PR #10069 docs(5333): G5's destructive half — the design DECISION recorded — prose mention of #9889 in body — not a closing reference (non-blocking) (weak) (advisory — cannot block)

WEAK SIGNALS (reported, non-blocking — these do NOT block)
  1 a prose-only cross-reference(s) of #9889; no title / branch / worktree / closing-reference match.
  These do NOT block a dispatch.

INCOMPLETE SURFACES
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer — the board's lane registry could not be read (FileNotFoundError: [Errno 2] No such file or directory: '/home/cmux/.pi/agent/state/lane-registry.tsv') — the lane roster is UNKNOWN, not empty … (comment prose is not read, #8175)

ADVISORY SURFACES — reported only; these cannot block a dispatch
  [recently-closed PRs] 1 hit(s) — sampled the most recent 100 of ~4100 closed PR(s)
  NOTE: a match here is on a TERMINAL PR — immutable history, not in-flight work.

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be FULLY queried (issue assignee/holder); this is NOT clean for #9889 in daniel-ospina/tortoise — the LANE ROSTER is UNKNOWN (not empty) — no lane can be attributed to this issue until it is readable
REPORT
  CELL2952_REPORT="$(cat "$TMP/cell2952.report")"
  # The registry answers the way a would-be dispatcher needs it to: CLEAN, nothing claimed.
  CELL2952="$(holder_report x "$CELL2952_REPORT")"
  holder_run "$CELL2952" b1
  # ⛔ `holder_queued` returns 1 for QUEUED ("1 = queued = FAIL code", its own doc) because it was
  # written for arms that assert a refusal. Both polarities appear below, so each one is spelled out:
  # a check that reads the raw helper value would be asserting the OPPOSITE of what its name says.
  r2952_is_queued() { [ "$(holder_queued "$1")" = 1 ]; }   # rc 0 = the candidate WAS queued
  # ⛔ BOTH directions, or a no-op re-route reads green: the candidate must be QUEUED **and** the
  # queue must be the SUBSTITUTION's doing (the echo names the board+registry path). Pre-fix, this
  # arm reds on the first assertion — the parse returned nothing, so the candidate was refused.
  if r2952_is_queued "$CELL2952"; then rc=0; else rc=1; fi
  ck "(2952a) the producer's REAL verdict wording ('could not be FULLY queried') is RE-ROUTED — the board is unreadable, the registry answers" $rc
  case "$(cat "$TMP/holder-b1.out")" in
    *"the pre-flight's HOLDER surface could not answer"*) rc=0 ;;
    *) rc=1 ;;
  esac
  ck "(2952a) …and it is the HOLDER substitution that queued it (not a silently different CLEAN path)" $rc
  case "$(cat "$TMP/holder-b1.out")" in
    *"+#10 CLEAN -> backlog"*) rc=0 ;;
    *) rc=1 ;;
  esac
  ck "(2952a) …and the queue entry was actually written (the positive half of the pair)" $rc
  # ── (2952b) THE REGISTRY IS THE ONLY AUTHORITY LEFT, SO AN UNREADABLE ONE STILL REFUSES ────────
  # Polarity, unchanged: the substitution moves the requirement from "a local board must answer" to
  # "the cross-box registry must answer". rc=2 is claims.sh's UNREADABLE verdict; it is INCOMPLETE,
  # never CLEAN, and the candidate must be neither queued nor retired.
  { printf 'issue_claim_verdict() { CLAIM_RESULT="the registry could not be read (stub)"; return 2; }\n'; cat "$TMP/refreshloop.sh"; } > "$TMP/refreshloop-2952.sh"
  CELL2952B="$(holder_report x "$CELL2952_REPORT")"
  r2952_run() { # <dir> <name>
    O="$1" LIMIT=5 SC="$1/fakesc" PY="$1/fakesc/.venv/bin/python" PREFLIGHT="$1/fakesc/tools/collision_preflight.py" \
      bash "$TMP/refreshloop-2952.sh" > "$TMP/2952-$2.out" 2>&1
  }
  r2952_run "$CELL2952B" b2
  if r2952_is_queued "$CELL2952B"; then rc=1; else rc=0; fi
  ck "(2952b) an UNREADABLE claims registry is still INCOMPLETE — not queued" $rc
  case "$(tr '\n' ' ' < "$CELL2952B/checked.txt")" in *10*) rc=1 ;; *) rc=0 ;; esac
  ck "(2952b) …and not retired: the claim is a window, so the candidate is re-attempted next pass" $rc
  case "$(cat "$TMP/2952-b2.out")" in
    *"?#10 INCOMPLETE — the registry could not be read"*) rc=0 ;;
    *) rc=1 ;;
  esac
  ck "(2952b) …and the refusal names the REGISTRY as the reason (not the board, which was substituted)" $rc
  # …and the OTHER form of "unreadable": the registry is not INSTALLED at all. Nothing has answered the
  # holder question then, so a CLEAN here would mean "no registry, therefore nobody holds it" — the
  # fail-open this whole substitution is shaped to avoid. (The pre-#2952 arm `(ii-b)` pins the same
  # wiring on the OLD wording; this one pins it on the producer's real one.)
  CELL2952B2="$(holder_report x "$CELL2952_REPORT")"
  rm -f "$CELL2952B2/claims.sh"
  r2952_run "$CELL2952B2" b2b
  if r2952_is_queued "$CELL2952B2"; then rc=1; else rc=0; fi
  ck "(2952b) an ABSENT claims registry is still INCOMPLETE — not queued (no registry is not a free issue)" $rc
  case "$(cat "$TMP/2952-b2b.out")" in
    *"is NOT INSTALLED"*) rc=0 ;;
    *) rc=1 ;;
  esac
  ck "(2952b) …and the refusal names the MISSING registry (the substituted authority is required, not optional)" $rc
  # ── (2952c) A SECOND GENUINELY-UNREADABLE SURFACE STILL REFUSES ───────────────────────────────
  # The other half of the same defect class: `issue landed` is answerable on a cell (gh reads the
  # issue's state and timeline fine), so it must NOT be swept into the substitution — and it is not,
  # because the surrogate is the CAUSE (the board), never a surface COUNT. A landed surface that
  # cannot answer for its OWN reason is work the tool could not judge. Report abridged from cell4's
  # `collision_preflight.py 2218` (same day, same box); its verdict line names BOTH surfaces.
  CELL2952C="$(holder_report x "issue landed                    INCOMPLETE  0     issue-state-uninterpretable: state='MERGED' is neither OPEN nor CLOSED, so whether this work item is still live cannot be established — refusing to read it as free (NOT clean)
issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer — the board's lane registry could not be read (FileNotFoundError: /home/cmux/.pi/agent/state/lane-registry.tsv)

INCOMPLETE SURFACES
  [issue landed] issue-state-uninterpretable: state='MERGED' is neither OPEN nor CLOSED, so whether this work item is still live cannot be established — refusing to read it as free (NOT clean)
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer — the board's lane registry could not be read (FileNotFoundError: /home/cmux/.pi/agent/state/lane-registry.tsv)

VERDICT: INCOMPLETE (exit 2) — 2 surface(s) could not be FULLY queried (issue landed, issue assignee/holder); this is NOT clean for #2218 in daniel-ospina/tortoise — PART of this is the LANE ROSTER is UNKNOWN (not empty)")"
  { printf 'issue_claim_verdict() { CLAIM_RESULT="stub: no claim"; return 0; }\n'; cat "$TMP/refreshloop.sh"; } > "$TMP/refreshloop-2952.sh"
  r2952_run "$CELL2952C" b3
  if r2952_is_queued "$CELL2952C"; then rc=1; else rc=0; fi
  ck "(2952c) a SECOND unreadable surface (issue landed, its own cause) is NOT re-routed — the work itself is unjudged" $rc
  case "$(cat "$TMP/2952-b3.out")" in
    *"?#10 INCOMPLETE from the pre-flight"*) rc=0 ;;
    *) rc=1 ;;
  esac
  ck "(2952c) …and it is the pre-flight's INCOMPLETE arm that refused it (the guard fired, it did not no-op)" $rc
  # ── (2952d) A DIFFERENT ADVERB IS STILL THE SAME CONTRACT ────────────────────────────────────
  # This is the arm that makes the fix a CONTRACT rather than a widened literal: the producer is not
  # vendored, so the next reword must not silently re-break the re-route. Any `could not be … queried`
  # renders the set; a verdict line with NO parenthetical at all renders nothing, and then the pass
  # REFUSES **loudly** (the drift echo) instead of returning to a silent `0 dispatched`.
  CELL2952D="$(holder_report x 'issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer — the board lane registry could not be read

INCOMPLETE SURFACES
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer — the board lane registry could not be read

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be PARTIALLY queried (issue assignee/holder); this is NOT clean')"
  { printf 'issue_claim_verdict() { CLAIM_RESULT="stub: no claim"; return 0; }\n'; cat "$TMP/refreshloop.sh"; } > "$TMP/refreshloop-2952.sh"
  r2952_run "$CELL2952D" b4
  if r2952_is_queued "$CELL2952D"; then ck "(2952d) an adverb the producer has NOT used yet keeps the re-route alive (the anchor is 'queried (', not the phrase)" 0; else ck "(2952d) an adverb the producer has NOT used yet keeps the re-route alive (the anchor is 'queried (', not the phrase)" 1; fi
  # (2952e) …and the DRIFT case is REFUSED **and ANNOUNCED**: no parenthetical → nothing to re-route
  # on, plus a WARN naming the drift. Silence here is what cost six days on cell4.
  CELL2952E="$(holder_report x 'issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer — the board lane registry could not be read

INCOMPLETE SURFACES
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer — the board lane registry could not be read

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) is unreadable; this is NOT clean')"
  r2952_run "$CELL2952E" b5
  if r2952_is_queued "$CELL2952E"; then rc=1; else rc=0; fi
  ck "(2952e) a verdict line with NO surface list is NOT re-routed (drift fails CLOSED)" $rc
  case "$(cat "$TMP/2952-b5.out")" in
    *"WARN: #10 the pre-flight's VERDICT LINE carried no readable surface list"*) rc=0 ;;
    *) rc=1 ;;
  esac
  ck "(2952e) …and the drift is ANNOUNCED, not swallowed (a silent no-op is what must not recur)" $rc

  # ── (2952f–i) THE CELL'S REAL SHAPE: TWO SURFACES, ONE CAUSE (agent-infra#2952) ─────────────────
  # ⛔ (2952a)–(2952e) ABOVE PINNED THE *PARSER* — they all carry a verdict line naming ONE surface,
  # which is NOT the shape a cell produces. #2952's headline defect is the one they cannot see: the
  # claim gate ABORTS the whole issue scan on a cell, so the producer records ONE inability as TWO
  # unreadable surfaces, both carrying the SAME board note:
  #   `2 surface(s) could not be FULLY queried (issue landed, issue assignee/holder)`
  # #1935 required the holder surface to be named ALONE, so `HOLDER_ONLY` was 0 for every cell
  # candidate and the substitution could never fire — measured as `12 unjudged`, `227 not reached`,
  # `0 dispatched`, every pass, with the whole pre-flight budget spent refusing candidates the box
  # could have judged. The condition is the CAUSE, so these arms key on it:
  #   (f) every named surface's cause is the unanswerable board + the holder is named → JUDGED;
  #   (g) …and an UNREADABLE registry is still INCOMPLETE (the substitution moves the requirement,
  #       it does not remove it) — the same report, only the registry's verdict changed;
  #   (h) a board-caused set that does NOT name the holder surface → refused (nothing to substitute);
  #   (i) a surface the verdict line NAMES but the parser cannot read a cause for → refused,
  #       because "no cause" must never satisfy "every cause is the board".
  # ⛔ (g) IS THE POLARITY ARM AND IT IS DELIBERATELY THE *SAME FIXTURE* AS (f): if the two ever
  # disagree the difference is the registry's answer and nothing else, so a mutant that drops the
  # registry requirement reds (g) while (f) stays green — which is what makes (f) non-vacuous.
  cat > "$TMP/cell2952-multi.report" <<'REPORT'
issue landed                    INCOMPLETE  0     claim gate: the FLEET BOARD could not answer — the board lane registry could not be read (FileNotFoundError: [Errno 2] No such file or directory: '/home/cmux/.pi/agent/state/lane-registry.tsv')
issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer — the board lane registry could not be read (FileNotFoundError: [Errno 2] No such file or directory: '/home/cmux/.pi/agent/state/lane-registry.tsv')

INCOMPLETE SURFACES
  [issue landed] claim gate: the FLEET BOARD could not answer — the board lane registry could not be read
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer — the board lane registry could not be read

VERDICT: INCOMPLETE (exit 2) — 2 surface(s) could not be FULLY queried (issue landed, issue assignee/holder); this is NOT clean for #2218 in daniel-ospina/tortoise — PART of this is the LANE ROSTER is UNKNOWN (not empty)
REPORT
  CELL2952F="$(holder_report x "$(cat "$TMP/cell2952-multi.report")")"
  { printf 'issue_claim_verdict() { CLAIM_RESULT="stub: no claim"; return 0; }\n'; cat "$TMP/refreshloop.sh"; } > "$TMP/refreshloop-2952.sh"
  r2952_run "$CELL2952F" f1
  if r2952_is_queued "$CELL2952F"; then rc=0; else rc=1; fi
  ck "(2952f) the CELL's real verdict (TWO surfaces, ONE board cause) is JUDGED — the registry answers the one open question" $rc
  case "$(cat "$TMP/2952-f1.out")" in
    *"the pre-flight's HOLDER surface could not answer"*) rc=0 ;;
    *) rc=1 ;;
  esac
  ck "(2952f) …and it was the HOLDER substitution that judged it (not a silently different CLEAN path)" $rc
  # (2952g) THE POLARITY, ON THE SAME REPORT: the substitution moves the requirement from "a local
  # board must answer" to "the cross-box registry must answer". An unreadable registry answers
  # nothing, so the candidate is INCOMPLETE and is neither queued nor retired.
  CELL2952G="$(holder_report x "$(cat "$TMP/cell2952-multi.report")")"
  { printf 'issue_claim_verdict() { CLAIM_RESULT="the registry could not be read (stub)"; return 2; }\n'; cat "$TMP/refreshloop.sh"; } > "$TMP/refreshloop-2952.sh"
  r2952_run "$CELL2952G" f2
  if r2952_is_queued "$CELL2952G"; then rc=1; else rc=0; fi
  ck "(2952g) …with an UNREADABLE registry the SAME report is still INCOMPLETE — the cause keys the arm, not the count" $rc
  case "$(tr '\n' ' ' < "$CELL2952G/checked.txt")" in *10*) rc=1 ;; *) rc=0 ;; esac
  ck "(2952g) …and not retired (a claim is a window, so the candidate is re-attempted next pass)" $rc
  # ⛔ A READABLE REGISTRY IS WHAT MAKES (h) AND (i) FALSIFIABLE (review P1, this round). (g) leaves
  # the shared stub at rc 2, and with an UNREADABLE registry EVERY candidate below is refused by the
  # registry requirement ALONE — so both arms read green even with the whole cause-set condition
  # deleted, and the membership test they are recorded as pinning had NO assertion that could turn
  # red (measured: the mutant queues neither, on either stub). Re-stub it READABLE: the refusal must
  # then come from the membership test and nothing else, or the two arms are decoration.
  {
    printf 'issue_claim_verdict() { CLAIM_RESULT="stub: no claim"; return 0; }\n'
    cat "$TMP/refreshloop.sh"
  } > "$TMP/refreshloop-2952.sh"
  # (2952h) A BOARD-CAUSED SET WITHOUT THE HOLDER SURFACE. The cause matches, so the cause alone would
  # re-route it — but there is no holder answer to substitute, so nothing may be judged.
  # ⛔ WHAT THIS ARM DOES *NOT* PIN (review P1, this round): it cannot red from the cause-set condition
  # alone. With the condition DELETED the candidate is still refused, because the substitution's own
  # downstream requirement — a parsed `issue assignee/holder` ROW whose note is the board's (the
  # `holder_note` gate below, #1935/#1977) — has nothing to match. So this arm is a pin on the
  # COMPOSITE refusal (defence in depth: it reds only if BOTH that gate and the condition are gone),
  # and it is NOT the assertion that condition 3 is live. (2952i) is, and was rebuilt to be.
  CELL2952H="$(holder_report x 'issue landed                    INCOMPLETE  0     claim gate: the FLEET BOARD could not answer — the board lane registry could not be read

INCOMPLETE SURFACES
  [issue landed] claim gate: the FLEET BOARD could not answer — the board lane registry could not be read

VERDICT: INCOMPLETE (exit 2) — 1 surface(s) could not be FULLY queried (issue landed); this is NOT clean')"
  r2952_run "$CELL2952H" f3
  if r2952_is_queued "$CELL2952H"; then rc=1; else rc=0; fi
  ck "(2952h) a board-caused INCOMPLETE that does NOT name the holder surface is REFUSED (nothing to substitute)" $rc
  # (2952i) A SURFACE THE VERDICT LINE NAMES, WITH NO CAUSE THIS READER CAN FIND. The cause test is
  # SET MEMBERSHIP over the parsed rows, so an unparsed surface has no cause at all — and "no cause"
  # must never read as "the board's cause", or the arm fails OPEN on a parser miss.
  # ⛔ THE HOLDER ROW *IS* PARSED HERE, DELIBERATELY (review P1, this round). The earlier fixture named
  # the holder in the verdict line and left its row out, which meant the downstream `holder_note` gate
  # refused the candidate whatever this condition did — the arm read green with the whole condition
  # deleted (measured, M4), so it pinned nothing. The absent surface is therefore a THIRD one (`open
  # PRs`, a real slug — see the D5 fixture above) while BOTH board-caused rows are present: the holder
  # answer exists and the registry is READABLE, so the ONLY thing between this candidate and the
  # registry is the membership test. That is what makes the arm able to fail, and it is the FAIL-OPEN
  # it now pins: a surface the tool could not read is queued as verified.
  CELL2952I="$(holder_report x 'issue landed                    INCOMPLETE  0     claim gate: the FLEET BOARD could not answer — the board lane registry could not be read
issue assignee/holder           INCOMPLETE  0     claim gate: the FLEET BOARD could not answer — the board lane registry could not be read

INCOMPLETE SURFACES
  [issue landed] claim gate: the FLEET BOARD could not answer — the board lane registry could not be read
  [issue assignee/holder] claim gate: the FLEET BOARD could not answer — the board lane registry could not be read

VERDICT: INCOMPLETE (exit 2) — 3 surface(s) could not be FULLY queried (issue landed, issue assignee/holder, open PRs); this is NOT clean')"
  r2952_run "$CELL2952I" f4
  if r2952_is_queued "$CELL2952I"; then rc=1; else rc=0; fi
  ck "(2952i) a surface NAMED by the verdict line but ABSENT from the parsed set is REFUSED (no cause is not the board's)" $rc
fi

# ── 5m) REPO has NO path default — required, or derived from a checkout of the QUEUE's repo ─────
# `REPO="${REPO:-/Users/danielospina/Documents/GitHub/tortoise}"` made one developer's home
# directory the default checkout on every machine (#1935). These cases drive the SHIPPED script's
# own `--check`, so what is pinned is the real resolver, not a re-implementation of it.
RH="$TMP/repohome"; mkdir -p "$RH/cell"
if ( unset REPO; unset TORTOISE_REPO; unset WORKDIR; unset TORTOISE
     HOME="$RH" O="$TMP/repohome/o" OR=acme/widget bash "$REFRESH" --check > "$TMP/repo-none.out" 2>&1 ); then rc=1; else rc=0; fi
ck "REPO unset with no derivable checkout REFUSES (non-zero, not a guess)" $rc
case "$(cat "$TMP/repo-none.out")" in *"acme/widget"*) rc=0;; *) rc=1;; esac
ck "the refusal NAMES the queue target it looked for" $rc
case "$(cat "$TMP/repo-none.out")" in *"set REPO="*) rc=0;; *) rc=1;; esac
ck "the refusal carries the one-line remedy (set REPO=…)" $rc
# A checkout of a DIFFERENT repo at the same candidate path must NOT be adopted: the queue target and
# the checkout must be the same repo, or the cell queues work it cannot pre-flight (#1901).
git -C "$RH/cell" init -q 2>/dev/null && git -C "$RH/cell" remote add origin https://github.com/acme/other.git
( unset REPO; unset TORTOISE_REPO; unset WORKDIR; unset TORTOISE
  HOME="$RH" O="$TMP/repohome/o2" OR=acme/widget bash "$REFRESH" --check > "$TMP/repo-wrong.out" 2>&1 ) || true
case "$(cat "$TMP/repo-wrong.out")" in *"REPO was not set"*) rc=1;; *) rc=0;; esac
ck "a checkout of the WRONG repo at a candidate path is NOT adopted" $rc
# …and the same path with the right origin IS adopted (the false-block control).
git -C "$RH/cell" remote set-url origin https://github.com/acme/widget.git
( unset REPO; unset TORTOISE_REPO; unset WORKDIR; unset TORTOISE
  HOME="$RH" O="$TMP/repohome/o3" OR=acme/widget bash "$REFRESH" --check > "$TMP/repo-ok.out" 2>&1 ) || true
# ⛔ THE EXPECTED PATH IS THE RESOLVER'S `pwd -P` FORM, NOT THE `$TMP`-SPELLED ONE (#1935 review,
# P2). `resolve_repo` prints the value AFTER `cd "$cand" && pwd -P` (`REPO="$(cd "$cand" && pwd -P)"`),
# so on macOS — where `$TMPDIR` is `/var/folders/…` and `/var` is a symlink to `/private/var` — a
# literal `$RH/cell` matches nowhere and this positive control reds for an unrelated reason. Same rule
# the claim-cwd suite states (`pwd -P` comparisons) and refresh-scout applies to its expected side.
RH_REAL="$(cd "$RH/cell" && pwd -P)"
case "$(cat "$TMP/repo-ok.out")" in *"REPO was not set — using $RH_REAL"*) rc=0;; *) rc=1;; esac
ck "a checkout whose origin IS the queue target is DERIVED (the resolver's positive path)" $rc
# An EXPLICIT $REPO is held to the same proof (cycle-2 review, F3). It used to be adopted on trust, so
# `refresh --check` returned CHECK OK for a pair that `cloud-cell-supervisor.sh check` refuses — and
# bring-up hands this script whatever checkout it finds, so a wrong pair was certified by the gate that
# exists to catch it. Three arms: mismatch refused, unreadable origin refused, match accepted.
#
# ⛔ THE FIXTURES MUST BE PROVISIONABLE, OR EVERY ARM MEASURES THE WRONG GATE (measured in CI: this
# block was RED on the PR lane and GREEN on the author's box). `--check` judges MORE than the repo
# resolver: after `resolve_repo` it runs the #1736 provisioning gate, which refuses (rc 3) a repo
# carrying no `tools/collision_preflight.py` and no resolvable tortoise checkout. The fixture repos
# had neither, so out of the box the mismatch and no-origin arms passed for a reason that had nothing
# to do with the origin check (that pass is VACUOUS pre-F3, since a trusted-on-sight repo also exits
# non-zero there), and the accepted arm FAILED — the false block this test exists to forbid — with no
# resolver involved at all. The author's box only passed because an ambient $TORTOISE_REPO resolved
# the tool; the runner has none. So: the tools are VENDORED into each fixture (existence is all
# `resolve_preflight` reads) and the three env seams the resolver consults are UNSET, exactly as the
# derived arms above do. Each arm then isolates the property it names.
X="$TMP/repoexplicit"; mkdir -p "$X/other/tools" "$X/samerepo/tools"
for d in "$X/other" "$X/samerepo"; do
  printf '# fixture: `--check` only tests that the pre-flight tool EXISTS (#1736)\n' > "$d/tools/collision_preflight.py"
done
git -C "$X/other" init -q; git -C "$X/other" remote add origin https://github.com/acme/other.git
( unset TORTOISE_REPO; unset TORTOISE; unset WORKDIR
  HOME="$RH" REPO="$X/other" OR=acme/widget O="$TMP/repoexplicit/o" bash "$REFRESH" --check > "$TMP/repo-explicit-mismatch.out" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ]; then xr=0; else xr=1; fi
ck "an EXPLICIT REPO whose origin is a DIFFERENT repo is REFUSED (the two entry points agree, #1901)" $xr
case "$(cat "$TMP/repo-explicit-mismatch.out")" in
  *"NOT the queue target"*) xr=0 ;;
  *) xr=1 ;;
esac
ck "the mismatch refusal names the queue target and the checkout's origin" $xr
# The mismatch arm must fail for the ORIGIN reason, not because the fixture was unprovisionable:
# assert the provisioning gate is satisfiable here, or the arm above is vacuous.
case "$(cat "$TMP/repo-explicit-mismatch.out")" in
  *"no tools/collision_preflight.py"*) xr=1 ;;
  *) xr=0 ;;
esac
ck "the mismatch arm's fixture IS provisionable (the refusal is the origin check, not #1736)" $xr
git -C "$X/samerepo" init -q   # …a checkout with NO origin cannot prove anything either
( unset TORTOISE_REPO; unset TORTOISE; unset WORKDIR
  HOME="$RH" REPO="$X/samerepo" OR=acme/widget O="$TMP/repoexplicit/o2" bash "$REFRESH" --check > "$TMP/repo-explicit-noorigin.out" 2>&1 ); rc=$?
if [ "$rc" -ne 0 ]; then xr=0; else xr=1; fi
ck "an EXPLICIT REPO with NO readable origin is REFUSED (cannot-prove is not proved)" $xr
# …and refused BY THE ORIGIN CHECK: an rc-only assertion also passes when the resolver ADOPTED the
# checkout on trust and #1736 refused it, which is exactly the pre-F3 behaviour this arm forbids.
case "$(cat "$TMP/repo-explicit-noorigin.out")" in
  *"has no readable 'origin'"*) xr=0 ;;
  *) xr=1 ;;
esac
ck "the no-origin refusal names the missing remote (not a downstream provisioning failure)" $xr
git -C "$X/samerepo" remote add origin https://github.com/acme/widget.git
( unset TORTOISE_REPO; unset TORTOISE; unset WORKDIR
  HOME="$RH" REPO="$X/samerepo" OR=acme/widget O="$TMP/repoexplicit/o3" bash "$REFRESH" --check > "$TMP/repo-explicit-ok.out" 2>&1 )
# The ACCEPTANCE is asserted on the resolver's own line, not on rc: `[refresh] check: repo=…` is printed
# ONLY after `resolve_repo` returns 0, so it cannot pass when the resolver refused — and unlike rc it
# does not move when the box's `python3` is older than the tool's floor (the interpreter judge runs
# AFTER the resolver and would turn a correct acceptance into a non-zero exit; that is a different
# gate's red, and pinning rc here made THIS arm fail for it).
case "$(cat "$TMP/repo-explicit-ok.out")" in
  *"[refresh] check: repo=$X/samerepo"*) xr=0 ;;
  *) xr=1 ;;
esac
ck "an EXPLICIT REPO that IS a checkout of the queue target is ACCEPTED (no false block)" $xr
case "$(cat "$TMP/repo-explicit-ok.out")" in
  *"NOT the queue target"*|*"has no readable 'origin'"*) xr=1 ;;
  *) xr=0 ;;
esac
ck "the accepted arm carries NO resolver refusal (the acceptance is not a stray rc)" $xr
# ⛔ THE ONE PAIR ON WHICH THE TWO VERBS STILL DISAGREE, PINNED AS A DECLARED RESIDUAL (review F2).
# An explicit $REPO whose `origin` is a FILESYSTEM PATH with $OR UNDECLARED cannot be cross-checked
# here (there is nothing to compare a path to), so `resolve_repo` announces it and returns 0 — while
# `cloud-cell-supervisor.sh check` calls `queue_repo_from_url` on the same path, gets nothing, sets
# `underivable` and DIES. That is the local bare mirror this suite's own fixtures clone from, i.e.
# reachable. The PR body used to claim the entry points "can no longer disagree about the same pair",
# which is false for exactly this shape; the claim is narrowed and the residual is stated in
# `resolve_repo` (see its DECLARED RESIDUAL note). This arm pins the residual AS A DECISION, so
# turning it into a refusal is a deliberate test edit with a stated reason — never a silent tightening
# that refuses every local dev clone (`git init` + `remote add origin <path>`).
XP="$TMP/repolocalpath"; mkdir -p "$XP/tools" "$XP/origin.git"
printf '# fixture: `--check` only tests that the pre-flight tool EXISTS (#1736)\n' > "$XP/tools/collision_preflight.py"
git -C "$XP/origin.git" init -q --bare
git -C "$XP" init -q; git -C "$XP" remote add origin "$XP/origin.git"
( unset OR; unset TORTOISE_REPO; unset TORTOISE; unset WORKDIR
  HOME="$RH" REPO="$XP" O="$TMP/repolocalpath/o" bash "$REFRESH" --check > "$TMP/repo-localpath.out" 2>&1 ) || true
case "$(cat "$TMP/repo-localpath.out")" in
  *"the pairing is not cross-checked"*) xr=0 ;;
  *) xr=1; echo "      out: $(cat "$TMP/repo-localpath.out" | head -3)" ;;
esac
ck "a local-path origin with an UNDECLARED \$OR is TOLERATED and ANNOUNCED (the stated residual, not silence)" $xr
case "$(cat "$TMP/repo-localpath.out")" in
  *"NOT PROVISIONABLE"*) xr=1 ;;
  *) xr=0 ;;
esac
ck "…and it is TOLERATED, not refused (the residual is the tolerance; a refusal here would block local dev clones)" $xr
case "$(cat "$TMP/repo-localpath.out")" in
  *"[refresh] check: repo=$XP"*) xr=0 ;;
  *) xr=1 ;;
esac
ck "…and the resolver really returned 0 for it (the NOTE is not printed on the way to a refusal)" $xr

# ⛔ "DECLARED" IS THE OPERATOR'S CLAIM, NOT THE VARIABLE'S PRESENCE (#1977 review, P1).
# `orch-loop.sh` EXPORTS `OR` on EVERY cycle — including the one where it fell back to its own default —
# so a child that reads mere presence as "declared" refuses the local-path checkout above on EVERY
# production pass (rc 3 → `.refresh-blocked` → a merge-only cell), while the loop's own comment calls
# that shape legitimate. The loop therefore passes its intent in `OR_OPERATOR_DECLARED`, and these
# three arms pin the distinction: intent=0 tolerates, intent=1 proves, no marker keeps the old rule.
( unset TORTOISE_REPO; unset TORTOISE; unset WORKDIR; unset OR_OPERATOR_DECLARED
  HOME="$RH" REPO="$XP" OR=acme/widget OR_OPERATOR_DECLARED=0 O="$TMP/repolocalpath/op0" bash "$REFRESH" --check > "$TMP/repo-localpath-loop.out" 2>&1 ) || true
case "$(cat "$TMP/repo-localpath-loop.out")" in
  *"cannot prove it is a checkout"*) xr=1 ;;
  *"the pairing is not cross-checked"*) xr=0 ;;
  *) xr=1; echo "      out: $(head -3 "$TMP/repo-localpath-loop.out")" ;;
esac
ck "an EXPORTED \$OR the loop DERIVED (OR_OPERATOR_DECLARED=0) does not refuse a local-path checkout" $xr
( unset TORTOISE_REPO; unset TORTOISE; unset WORKDIR; unset OR_OPERATOR_DECLARED
  HOME="$RH" REPO="$XP" OR=acme/widget OR_OPERATOR_DECLARED=1 O="$TMP/repolocalpath/op1" bash "$REFRESH" --check > "$TMP/repo-localpath-decl.out" 2>&1 ); rc=$?
[ "$rc" -eq 3 ] && xr=0 || xr=1
ck "an OPERATOR-DECLARED \$OR (OR_OPERATOR_DECLARED=1) still REFUSES a local-path checkout (rc=3)" $xr
# ⛔ AND THE REFUSAL IS THE ONLY MESSAGE. `repo_unresolved` speaks for an UNSET $REPO; on a rejected
# EXPLICIT one it appended "$REPO is not set" beside the true reason and prescribed the value already
# in hand — two contradictory refusals in one run (review P2).
case "$(cat "$TMP/repo-localpath-decl.out")" in
  *"is not set"*) xr=1 ;;
  *) xr=0 ;;
esac
ck "a REJECTED explicit \$REPO is not also reported as UNSET (one cause, one message)" $xr


# ── 5e) the capture site itself: a failed `gh` leaves ABSENCE, not an empty file ──────────────
# The reaper guard above is only sound if the capture never hands it an empty file for a FAILED
# read. Extract the shipped capture block and drive it with a stub `gh`: on failure NOTHING must be
# left behind (`rm -f`), and on success the (empty) file must be present — that difference is what
# lets the reaper tell "the read failed" from "the answer is none". The pre-fix `|| : > "$O/.pr_brs"`
# wrote an empty file in BOTH cases, which is the fail-open being fixed here. (agent-infra#1705)
# ⛔ THE ANCHOR MOVED WITH THE TRANSPORT (#1962), IT WAS NOT LOOSENED. The capture is now
# `rest_list …` (a REST helper) instead of `gh issue list …` (GraphQL), so the extraction starts at
# the helper section — which the captured lines CALL — and still stops after the SECOND capture
# block. Anchoring below the helpers would have extracted two calls to an undefined function: both
# "leaves NO .open_iss" checks would then pass for the wrong reason (command-not-found) while the
# "a SUCCESSFUL empty listing leaves an EMPTY .pr_brs" check below went red.
awk '/^# ── THE LISTINGS RUN ON THE REST BUCKET/{f=1} f{print} f&&/^fi$/{c++; if(c==2) exit}' "$REFRESH" > "$TMP/acq.sh"
if need "$TMP/acq.sh" "the listing capture (with its REST helper) is extracted from the shipped refresh-candidates.sh"; then
  A="$TMP/acq"; mkdir -p "$A/fail" "$A/ok"
  # ⛔ THE STUB ANSWERS IN `gh api -i` SHAPE, because that is what the shipped helper reads. It parses
  # the response HEADERS (the `Link` header decides whether the collection ended) and only accepts an
  # EMPTY body when the status line says 204 — a bare `exit 0` would look like a 200 with no body,
  # which is refused on purpose (a vanished body is not "no rows": it would write an EMPTY `.pr_brs`).
  # So "a successful empty listing" is `200` + `[]`, which is exactly what GitHub returns.
  cat > "$A/gh" <<'SH'
#!/bin/bash
case "${GH_MODE:-}" in
  fail) echo 'gh: could not reach api.github.com' >&2; exit 1 ;;
  ok)   printf 'HTTP/2.0 200 OK\r\ncontent-type: application/json\r\n\r\n[]\n' ;;
esac
SH
  chmod +x "$A/gh"
  ( PATH="$A:$PATH" GH_MODE=fail O="$A/fail" OR="acme/widget" bash "$TMP/acq.sh" ) > "$TMP/acq-fail.out" 2>&1
  [ ! -e "$A/fail/.pr_brs" ] && rc=0 || rc=1
  ck "shipped capture: a FAILED PR listing leaves NO .pr_brs (absence, not an empty answer)" $rc
  [ ! -e "$A/fail/.open_iss" ] && rc=0 || rc=1
  ck "shipped capture: a FAILED issue listing leaves NO .open_iss" $rc
  ( PATH="$A:$PATH" GH_MODE=ok O="$A/ok" OR="acme/widget" bash "$TMP/acq.sh" ) > "$TMP/acq-ok.out" 2>&1
  [ -e "$A/ok/.pr_brs" ] && [ ! -s "$A/ok/.pr_brs" ] && rc=0 || rc=1
  ck "shipped capture: a SUCCESSFUL empty PR listing leaves an EMPTY .pr_brs (a real answer)" $rc
fi

# ── 6) install.sh renders correctly, including values sed/XML would mangle ────────
# Runs the real installer with a hostile-but-LEGAL $O. "Legal" matters: install.sh now applies
# orch-loop.sh's own $O guard, so a quote or shell metacharacter (`&`, `'`, space, …) is refused
# at install time — which is the point, since such a value would crash-loop the daemon under
# KeepAlive. What remains reachable, and is tested here, is XML metacharacter escaping (`<`, `>`,
# a bare one of which makes the plist invalid XML and launchd silently refuses to load it) plus the
# round-trip decode below. (Historical: an unescaped `&` in the sed REPLACEMENT expanded to the
# matched text, rendering `O=/tmp/a&b` as /tmp/a__O__b — a VALID plist pointing at the wrong paths,
# which plutil -lint cannot catch. That path is now unreachable by construction and the guard is
# asserted in 16d.)
SB="$TMP/sb"; mkdir -p "$SB/Library/LaunchAgents" "$SB/.config" "$SB/.pi/agent/scripts"
ln -s "$HOME/.config/gh" "$SB/.config/gh" 2>/dev/null || true
[ -f "$HOME/.pi/agent/scripts/record-review.sh" ] && ln -s "$HOME/.pi/agent/scripts/record-review.sh" "$SB/.pi/agent/scripts/record-review.sh"
# install.sh prefers the version-independent pi-node symlink under $HOME, and the daemon probe now
# EXECUTES pi — so a sandbox HOME must expose a runnable pi, exactly as a real install's HOME does.
mkdir -p "$SB/.local/share/pi-node/current/bin"
printf '#!/bin/bash\nexit 0\n' > "$SB/.local/share/pi-node/current/bin/pi"; chmod +x "$SB/.local/share/pi-node/current/bin/pi"
if on_darwin; then
HOSTILE="$TMP/x<y>z"
HOME="$SB" O="$HOSTILE" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >"$TMP/inst.out" 2>&1
PL="$SB/Library/LaunchAgents/$TPL"
[ -f "$PL" ] && rc=0 || { rc=1; echo "      install.sh did not render a plist: $(tail -3 "$TMP/inst.out")"; }
ck "install.sh renders a plist" $rc
if [ -f "$PL" ]; then
  grep -q '__[A-Z_]*__' "$PL" && rc=1 || rc=0
  ck "no unsubstituted placeholder survives rendering" $rc
  # The value must appear XML-escaped (a bare < or > is illegal XML); correctness is then proven
  # by the round-trip check below, which decodes it back and compares.
  grep -qF 'x&lt;y&gt;z' "$PL" && rc=0 || { rc=1; echo "      expected XML-escaped '<' '>' in the plist"; }
  ck "a '<'/'>' in a path is XML-escaped in the plist" $rc
  plutil -lint "$PL" >/dev/null 2>&1 && rc=0 || rc=1
  ck "the rendered plist is valid XML" $rc
  # Round-trip: XML-escaping must decode back to the original path, not merely be well-formed.
  decoded="$(plutil -extract EnvironmentVariables.O raw "$PL" 2>/dev/null || echo MISSING)"
  [ "$decoded" = "$HOSTILE" ] && rc=0 || { rc=1; echo "      decoded '$decoded' != '$HOSTILE'"; }
  ck "the hostile path round-trips through the plist unchanged" $rc
  # Provenance (#1745): the REAL installer must leave a record at $O, on the SAME install that
  # rendered the plist — a record written only by a separate command is a record nobody runs.
  [ -f "$HOSTILE/.agent-infra-stamp.json" ] && rc=0 || { rc=1; echo "      install.sh wrote no provenance stamp at $HOSTILE"; }
  ck "install.sh records the harness provenance at \$O (#1745)" $rc
  grep -qE '"payloadSha256": "[0-9a-f]{64}"|"payloadSha256": "UNKNOWN"' "$HOSTILE/.agent-infra-stamp.json" 2>/dev/null && rc=0 || rc=1
  ck "the recorded stamp carries a payload hash or an explicit UNKNOWN" $rc
fi
else
  skipd "install.sh renders a plist (§6) — install.sh is macOS-only (launchd); skipped on $PLATFORM"
fi

# ── 6b) install.sh on a fresh checkout: dir-only gitignore, .worktrees not created yet ─
# install.sh is the FIRST step on a fresh box (README §4) and dispatch-merge.sh creates the
# worktree lazily — but `git check-ignore -q .worktrees` returns non-zero when the path does not
# exist and the repo ignores it with the directory-only pattern `.worktrees/`. The installer then
# died before rendering the plist. Reproduced in a throwaway git repo whose parent is not a repo.
FR="$TMP/freshrepo"; mkdir -p "$FR/repo"
git -C "$FR/repo" init -q >/dev/null 2>&1
printf '.worktrees/\n' > "$FR/repo/.gitignore"
# Non-vacuous: this exact repo really does defeat the pre-fix bare-path form.
( cd "$FR/repo" && git check-ignore -q .worktrees ) && rc=1 || rc=0
ck "non-vacuity: the pre-fix bare .worktrees guard fails on a fresh checkout" $rc
grep -q 'check-ignore -q .worktrees/' "$INST" && rc=0 || rc=1
ck "install.sh's gitignore guard uses the directory form .worktrees/" $rc
if on_darwin; then
SB2="$TMP/sb2"; mkdir -p "$SB2/Library/LaunchAgents" "$SB2/.config" "$SB2/.pi/agent/scripts"
ln -s "$HOME/.config/gh" "$SB2/.config/gh" 2>/dev/null || true
mkdir -p "$SB2/.local/share/pi-node/current/bin"
printf '#!/bin/bash\nexit 0\n' > "$SB2/.local/share/pi-node/current/bin/pi"; chmod +x "$SB2/.local/share/pi-node/current/bin/pi"
HOME="$SB2" O="$TMP/fresh-o" REPO="$FR/repo" OR="acme/widget" bash "$INST" > "$TMP/inst-fresh.out" 2>&1
PL2="$SB2/Library/LaunchAgents/$TPL"
[ -f "$PL2" ] && rc=0 || { rc=1; echo "      fresh checkout: $(tail -2 "$TMP/inst-fresh.out")"; }
ck "install.sh renders a plist on a fresh checkout (no .worktrees dir yet)" $rc
else
  skipd "install.sh renders on a fresh checkout (§6b) — install.sh is macOS-only (launchd); skipped on $PLATFORM"
fi

# ── 6c) the self-test resolves REPO to the checkout, not its parent ─────────────
# It passed `$HERE/../../..` (the PARENT of the repo root) to install.sh, which died
# "not a git checkout" on any fresh clone whose parent is not a git repo — the exact second box
# this harness exists to hand over. `$HERE/../..` is the root (check #13 already uses it).
grep -qE 'REPO="\$HERE/\.\./\.\./\.\."' "$HERE/selftest.sh" && rc=1 || rc=0
ck "selftest.sh does not point install.sh at the repo's parent" $rc
grep -qF 'REPO="$HERE/../.."' "$HERE/selftest.sh" && rc=0 || rc=1
ck "selftest.sh passes the repo root to install.sh" $rc
[ -e "$HERE/../../.git" ] && rc=0 || rc=1
ck "the repo-root path selftest.sh uses resolves to a git working tree" $rc

# ── 6d) the rendered plist PATH IS the resolved daemon PATH (the integration seam) ─────────────
# §17/§18 drive the extracted PATH-builder and probe, but nothing pinned that install.sh actually
# RENDERS $DAEMON_PATH into the plist. Review mutation (H) restored the pre-fix hardcoded base at the
# __PATH__ substitution and left the whole suite green — yet the rendered PATH is the fixed artifact.
# Render in a sandbox with a CONTROLLED PATH whose tools live in one fixture dir: the rendered PATH
# must contain it (so the check is red under the hardcoded base) and no shim/.pi segment. `uv` is
# deliberately absent, which also exercises the documented non-fatal-uv path end to end.
if on_darwin; then
FB="$TMP/pathbin"; mkdir -p "$FB" "$TMP/sb3/Library/LaunchAgents" "$TMP/sb3/.config" "$TMP/sb3/.pi/agent/scripts"
for b in tmux gh pi jq; do printf '#!/bin/bash\nexit 0\n' > "$FB/$b"; chmod +x "$FB/$b"; done
ln -s "$HOME/.config/gh" "$TMP/sb3/.config/gh" 2>/dev/null || true
# ⛔ AND THE STUB MUST STAY ON *EVERY* PATH THIS FILE HANDS THE INSTALLER (review finding, T5): this
# line used to be PATH="$FB:/usr/bin:/bin", which DROPPED $GSTUB, so install.sh's post-install banner read
# the REAL domain. Read-only that day — and one added mutating call away from the 2026-10-17 incident
# this whole file guards against.
HOME="$TMP/sb3" O="$TMP/path-o" REPO="$HERE/../.." OR="acme/widget" PATH="$FB:$GSTUB:/usr/bin:/bin" bash "$INST" > "$TMP/inst-path.out" 2>&1
PL3="$TMP/sb3/Library/LaunchAgents/$TPL"
[ -f "$PL3" ] && rc=0 || { rc=1; echo "      controlled-PATH install did not render: $(tail -3 "$TMP/inst-path.out")"; }
ck "install.sh renders with a controlled PATH (uv absent stays non-fatal)" $rc
PLP="$(plutil -extract EnvironmentVariables.PATH raw "$PL3" 2>/dev/null || echo MISSING)"
case ":$PLP:" in *":$FB:"*) rc=0;; *) rc=1; echo "      rendered PATH=$PLP lacks the resolved tool dir $FB";; esac
ck "the rendered plist PATH is resolved, not the pre-fix hardcoded base" $rc
case ":$PLP:" in *"/shims"*|*"/.pi/"*) rc=1;; *) rc=0;; esac
ck "the rendered plist PATH contains no */shims or */.pi/* segment" $rc
else
  skipd "install.sh's plist PATH render checks (§6d) — install.sh is macOS-only (launchd); skipped on $PLATFORM"
fi

# ── 6e) install.sh CREATES the plist directory ─────────────────────────────────
# Every sandbox above pre-creates $HOME/Library/LaunchAgents, so `mkdir -p "$(dirname "$PLIST")"`
# was pinned by NOTHING: deleting it left the suite fully green, while on the real path — a fresh
# HOME has no such directory — the render died with a raw redirect error after $O's state dirs were
# already created (the pre-fix half-install). Assert the directory is absent first (non-vacuity),
# then that install succeeds and the plist exists.
if on_darwin; then
SB4="$TMP/sb4"; mkdir -p "$SB4/.config" "$SB4/.pi/agent/scripts"
ln -s "$HOME/.config/gh" "$SB4/.config/gh" 2>/dev/null || true
[ -f "$HOME/.pi/agent/scripts/record-review.sh" ] && ln -s "$HOME/.pi/agent/scripts/record-review.sh" "$SB4/.pi/agent/scripts/record-review.sh"
mkdir -p "$SB4/.local/share/pi-node/current/bin"
printf '#!/bin/bash\nexit 0\n' > "$SB4/.local/share/pi-node/current/bin/pi"; chmod +x "$SB4/.local/share/pi-node/current/bin/pi"
[ -e "$SB4/Library/LaunchAgents" ] && rc=1 || rc=0
ck "non-vacuity: the fresh sandbox HOME has no Library/LaunchAgents" $rc
HOME="$SB4" O="$TMP/plistdir-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >"$TMP/inst-plistdir.out" 2>&1
inst_rc=$?
[ "$inst_rc" -eq 0 ] && [ -f "$SB4/Library/LaunchAgents/$TPL" ] && rc=0 \
  || { rc=1; echo "      install.sh rc=$inst_rc did not create the plist dir: $(tail -3 "$TMP/inst-plistdir.out")"; }
ck "install.sh creates the plist directory on a HOME that lacks it" $rc
else
  skipd "install.sh creates the plist directory (§6e) — install.sh is macOS-only (launchd); skipped on $PLATFORM"
fi

# ── 7) in-script defaults agree with install.sh's defaults ───────────────────────
# A limit documented in README §4 and rendered by install.sh must not be silently different in
# orch-loop.sh — MAX_REVIEW was 2 in the loop and 4 everywhere else.
rc=0
# Assert the EFFECTIVE default, not the source text.
#
# Pattern-matching the source was a losing game: four review rounds each closed one spelling of the
# same hole and left another -- a literal, an arithmetic default, a duplicate definition, a duplicate
# with no trailing newline, then an indented/bare/conditional reassignment. Each fix taught the regex
# one more trick while bash kept resolving assignments by its own rules. Executing the assignments and
# comparing what bash RESOLVES tests the property we actually care about (that the two files agree)
# rather than a spelling of it.
#
# KNOWN LIMIT, stated so this is not oversold: the regex only matches an assignment that BEGINS a line
# (optionally after `export`). A `readonly VAR=`, an assignment on the same line as an `if`, or one
# inside a function body written on one line are therefore NOT evaluated, and such a form would evade
# this check. Those spellings do not occur in either file and neither is a natural way to write a
# limit, but a check cannot be stronger than what it evaluates, so the guarantee is "the assignments
# either file actually uses agree", not "any conceivable bash file agrees".
#
# Only lines that assign a KNOWN limit var (or _NCPU, below) are evaluated -- never the whole script.
# ⛔ THE TWO NEW WINDOWS ARE IN HERE TOO (review finding P2-2 for #2124). `install.sh` RENDERS
# MERGE_PRIORITY_MAX_AGE_MIN and FUNNEL_MAX_AGE_MIN into the daemon's environment (template +
# `sed` + the validation loop) AND `orch-loop.sh` defaults them, and both are documented in README
# §4 — but neither was in this list, so the one property that matters ("the value the installer
# renders is the value the loop uses", which install.sh's own refusal of `0` invokes) was pinned by
# NOTHING on the cross-file axis. A future edit to one side alone (loop 240, installer/README 180)
# would run a manual/tmux controller and a launchd controller of the same box type on different gate
# windows, with every suite green. Both sides DO declare them as a plain `VAR="${VAR:-N}"` at column
# 0 (orch-loop.sh and install.sh), which is exactly what `_LIMIT_RE` evaluates — the `is_limit …
# || VAR=180` coercion line is a different claim (that a bad value is repaired), pinned by THIS file's
# §NGRD coercion driver (`nlim`), not by test-gates.sh (review round 2, note: the pointer was wrong).
# agent-infra#2223: MAX_RED_FIX / MAX_RED_FIX_TRIES are the red-fixer role's box and per-head caps.
# Both are declared `VAR="${VAR:-N}"` at column 0 in orch-loop.sh AND install.sh, rendered into the
# plist, and printed in the installer's `limits` line — i.e. they are limits in exactly the sense this
# list pins, and leaving them out would let one side move alone with every suite green.
# agent-infra#2054: PRODUCT_FLOOR is the same claim for the product work floor — loop default, installer
# validation and plist render must agree, or a launchd box (which inherits no shell environment) runs a
# different floor from a manual one with every suite green.
_LIMITS="MAX_LOAD MAX_LANES MAX_REVIEW MERGE_PRIORITY_AT MERGE_PRIORITY_MAX_AGE_MIN FUNNEL_MAX_AGE_MIN MAX_FIX MAX_FIX_TRIES MAX_RED_FIX MAX_RED_FIX_TRIES MIN_SWAP_FREE MIN_MEM_FREE_MB BATCH PRODUCT_FLOOR CYC"
# _NCPU is evaluated but not printed: MAX_LOAD is derived from it, so pinning it here (as an earlier
# version did) would hide a divergence in the one input the derived ceiling depends on.
_EVAL_VARS="$_LIMITS _NCPU"
_LIMIT_RE="^[[:space:]]*(export[[:space:]]+)?($(printf '%s|' $_EVAL_VARS | sed 's/|$//'))="
eff_defaults() {
  ( if [ "$1" = env ]; then
      # Second pass: the limits are SET. This distinguishes `VAR="${VAR:-4}"` (honours the
      # override) from a bare `VAR=4` (ignores it) -- two forms that resolve identically when the
      # variable is unset, so a single unset pass cannot tell them apart. They diverge exactly where
      # it matters: the launchd plist supplies these as environment, and it OVERRIDES the script.
      for v in $_LIMITS; do export "$v=997"; done
    else
      for v in $_LIMITS; do unset "$v"; done
    fi
    unset _NCPU
    eval "$(grep -E "$_LIMIT_RE" "$2" 2>/dev/null)"
    for v in $_LIMITS; do printf '%s=%s\n' "$v" "$(eval "printf '%s' \"\${$v:-UNSET}\"")"; done )
}
_da="$(eff_defaults unset "$LOOP"; eff_defaults env "$LOOP")"
_db="$(eff_defaults unset "$INST"; eff_defaults env "$INST")"
if [ -n "$_da" ] && [ "$_da" = "$_db" ]; then
  echo "      effective: $(printf '%s' "$_da" | tr '\n' ' ')"
else
  echo "      effective defaults DIFFER:"
  printf '%s\n' "$_da" > "$TMP/da.txt"; printf '%s\n' "$_db" > "$TMP/db.txt"
  diff "$TMP/da.txt" "$TMP/db.txt" 2>/dev/null | sed 's/^/        /'
  rc=1
fi
ck "orch-loop.sh and install.sh resolve the same effective defaults for every limit in _LIMITS ($(printf '%s' "$_LIMITS" | wc -w | tr -d ' '))" $rc
# ⛔ Non-vacuity of the comparison above. `eff_defaults` ALWAYS prints one line per var -- it emits
# `VAR=UNSET` for a limit it could not resolve -- so `_da` is never empty and two files that BOTH
# fail to define a limit compare equal as `UNSET=UNSET`, printing that as "agreement". Verified by
# mutation: deleting MIN_MEM_FREE_MB from BOTH files left this check green. Require every limit to
# resolve to a real default on its own.
rcu=0
case "$_da$_db" in
  *UNSET*) rcu=1; echo "      a limit resolves to UNSET -- no default was found in one of the files";;
esac
ck "every limit resolves to a real default in both files (not UNSET=UNSET)" $rcu
# ⛔ The agreement check above proves the two FILES agree; it cannot see both drifting TOGETHER, and
# the non-vacuity rule only requires NOT-UNSET. Pin the documented value of each host-independent
# limit (README §4's table). Mutation-verified: MIN_SWAP_FREE=0 in BOTH files left this whole section
# green while the swap gate became `[ "$SWFREE" -le 0 ]`, which can never bind — the back-pressure
# README §8 calls the box's real throttle, silently disabled. MAX_LOAD is excluded because its default
# is the host's core count; §8's nlim driver covers it behaviourally.
# ⛔ MAX_LANES JOINED IT (2026-10-17, owner ruling: the lane ceiling is "2.5x the number of CPUs").
# Its default is derived from `_NCPU` too now, so it cannot sit in a host-independent table — the
# driver immediately below pins the derivation BEHAVIOURALLY, against a substituted probe instead.
dval() { printf '%s\n' "$_db" | awk -F= -v k="$1" '$1==k{print $2}' | head -1; }
expect_lim="BATCH=2 CYC=240 FUNNEL_MAX_AGE_MIN=30 MAX_FIX=3 MAX_FIX_TRIES=3 MAX_REVIEW=4 MERGE_PRIORITY_AT=25 MERGE_PRIORITY_MAX_AGE_MIN=180 MIN_MEM_FREE_MB=512 MIN_SWAP_FREE=600 PRODUCT_FLOOR=1"
got_lim=""
for _k in BATCH CYC FUNNEL_MAX_AGE_MIN MAX_FIX MAX_FIX_TRIES MAX_REVIEW MERGE_PRIORITY_AT MERGE_PRIORITY_MAX_AGE_MIN MIN_MEM_FREE_MB MIN_SWAP_FREE PRODUCT_FLOOR; do
  got_lim="$got_lim $_k=$(dval "$_k")"
done
got_lim="${got_lim# }"
[ "$got_lim" = "$expect_lim" ] && rcv=0 || { rcv=1; echo "      limits differ from the documented defaults:"; echo "        expected: $expect_lim"; echo "        got:      $got_lim"; }
ck "every host-independent limit default matches README §4 (two files cannot drift together)" $rcv
# ⛔ THE LANE CEILING IS DERIVED, AND THAT IS DRIVEN — not restated (2026-10-17). The owner's ruling
# is "2.5x the number of CPUs", so the property to pin is: the SHIPPED assignment, given a core
# count, yields 2.5x that count with a FLOOR — and a failed or absurd probe falls back to a 4-core
# box's 2.5x. Every line this runs comes out of the file under test (its own `_NCPU` probe through
# `MAX_LANES`, plus the loop's own coercion); only the OS probe is substituted. So reverting either
# file to a flat 4 reddens every case, and deleting either BOUND reddens the nine-digit one.
# A vacuous extraction cannot pass: an empty range leaves `MAX_LANES` unset and every case fails.
lane_drv() { # <file> <probe-output> [explicit MAX_LANES] -> resolved MAX_LANES
  local f="$1" p="$2"
  { echo 'set -uo pipefail'
    grep -F 'is_num() {' "$f"; grep -F 'is_limit() {' "$f"
    printf 'sysctl() { printf "%%s\\n" %s; }\n' "'$p'"
    sed -n '/^_NCPU=/,/^MAX_REVIEW=/p' "$f"
    grep -E '^is_limit "\$\{MAX_LANES:' "$f"
    printf 'printf "%%s" "${MAX_LANES:-UNSET}"'
  } > "$TMP/lane-drive.sh"
  if [ $# -ge 3 ]; then env MAX_LANES="$3" bash "$TMP/lane-drive.sh" 2>&1
  else env -u MAX_LANES bash "$TMP/lane-drive.sh" 2>&1; fi
}
rcl=0; rk=0; lanes_cases=0
for _case in 10:25 4:10 3:7 1:2 0:10 garbage:10 9223372036854775808:10 999999999:10; do
  _p="${_case%%:*}"; _want="${_case##*:}"
  for _f in "$LOOP" "$INST"; do
    _got="$(lane_drv "$_f" "$_p")"
    [ "$_got" = "$_want" ] || { rcl=1; echo "      $(basename "$_f") _NCPU=$_p -> MAX_LANES='$_got', expected $_want"; }
  done
  lanes_cases=$((lanes_cases+1))
done
ck "MAX_LANES derives 2.5x cores (floored) in BOTH files, and a failed/absurd probe falls back to 10" $rcl
for _f in "$LOOP" "$INST"; do
  _got="$(lane_drv "$_f" 10 7)"
  [ "$_got" = "7" ] || { rk=1; echo "      $(basename "$_f") pinned MAX_LANES=7 on a 10-core probe -> '$_got', expected 7 (a pin must not be recomputed)"; }
  _got="$(lane_drv "$_f" 10 0)"
  [ "$_got" = "0" ] || { rk=1; echo "      $(basename "$_f") deliberate MAX_LANES=0 -> '$_got', expected 0 (only the derivation is bounded)"; }
done
ck "an explicit MAX_LANES still WINS (7 stays 7, a deliberate 0 stays 0 — never recomputed)" $rk
[ "$lanes_cases" = "8" ] && rc=0 || rc=1
ck "the lane-derivation driver ran all 8 probe cases (an empty case list cannot pass)" $rc
# README §4's table is the source the files are pinned against, so its MAX_LANES row must carry the
# derivation rather than a number the code no longer uses. ⛔ ANCHORED TO THE ROW, not the file: an
# unanchored grep stays green if the row reverts to `| MAX_LANES | 4 |` while the string survives
# anywhere else in 1,200 lines (found in review round 1).
grep -qE '^\| `MAX_LANES` \| \*\*derived\*\*: `10#\$_NCPU \* 5 / 2`' "$HERE/README.md" && rc=0 || rc=1
ck "README §4's MAX_LANES ROW documents the core-derived default, not a flat number" $rc

# ── 8) the dispatch gate consults load and names the binding gate ────────────────
# MAX_LOAD was rendered into the plist and documented, but never compared to anything.
grep -qE '\[ "\$L" -ge "\$MAX_LOAD" \]' "$LOOP" && rc=0 || rc=1
ck "dispatch gate compares load against MAX_LOAD" $rc
grep -q 'GATE_WHY=' "$LOOP" && rc=0 || rc=1
ck "dispatch skip message names the binding gate" $rc
# The greps above prove a comparison and a message EXIST -- not that the memory gate can FIRE.
# Mutating MIN_MEM_FREE_MB's default to 0 in BOTH files (so §7's agreement check stays green) left
# the entire suite green while the gate became `[ "$MEMAVAIL_MB" -le 0 ]`, which never binds.
# Pin the documented default, then DRIVE the shipped gate chain to prove it is a comparison.
mem_def="$(dval MIN_MEM_FREE_MB)"
swp_def="$(dval MIN_SWAP_FREE)"
[ "$mem_def" = "512" ] && rcd=0 || { rcd=1; echo "      MIN_MEM_FREE_MB resolves to '$mem_def' -- README documents 512"; }
ck "MIN_MEM_FREE_MB resolves to the documented 512MB default in the shipped files" $rcd
# ⛔ BY THE MARKERS, NOT BY `^  fi$` (agent-infra#2924/#2927). The chain's closing `fi` used to be the
# only bare `  fi` after the entry line, so the extraction could stop there; the gate VECTOR put each
# arm in its own guard, and several of those guards close on a bare `  fi` — the first one truncated
# the block to the merge-priority arm, ELEVEN assertions still passed and the three below went red.
# A marker is the range the code itself declares, so adding an arm cannot silently shorten the test.
GATE_BLOCK="$(sed -n '/^  GATE_WHY="\$(mp_reason/,/# \[gatevec:end\]/p' "$LOOP")"
[ -n "$GATE_BLOCK" ] && rcg=0 || { rcg=1; echo "      the gate chain could not be extracted from $LOOP"; }
ck "the dispatch gate chain is extractable from the shipped loop" $rcg
mrw() { # L LANES SWTOTAL SWFREE MEM_UNKNOWN MEMAVAIL_MB MAX_LOAD MAX_LANES MIN_SWAP MIN_MEM [WORKERS]
  ( L=$1; LANES=$2; SWTOTAL=$3; SWFREE=$4; MEM_UNKNOWN=$5; MEMAVAIL_MB=$6
    MAX_LOAD=$7; MAX_LANES=$8; MIN_SWAP_FREE=$9; MIN_MEM_FREE_MB=${10}; OPEN_N=0
    # ⛔ WORKERS IS REQUIRED (P3.2, second review round, 2026-10-14). It was omitted, so
    # `eval "$GATE_BLOCK"` emitted `WORKERS: unbound variable` SIX times on stderr and its FIRST
    # line — `GATE_WHY="$(mp_reason … "$WORKERS")"` — never executed. Every assertion still passed
    # because the gates below it produced the same GATE_WHY, so the gate chain's entry line was
    # UNTESTED. The `WORKERS=${11:-0}` default and the stderr assertion below are the fix.
    WORKERS=${11:-0}
    GATE_WHY=""; mp_reason() { :; }
    eval "$GATE_BLOCK"; printf '%s' "${GATE_WHY:-}" )
}
[ "$(mrw 1 0 0 9999 0 100 100 4 600 "$mem_def")" = "mem_avail=100M<=min_mem_free_mb=${mem_def}M" ] && rcw=0 || rcw=1
ck "the memory gate FIRES below the ceiling and names it (mem_avail<=min_mem_free_mb)" $rcw
[ -z "$(mrw 1 0 0 9999 0 9999 100 4 600 "$mem_def")" ] && rcw=0 || rcw=1
ck "the memory gate does NOT fire when available memory is above the ceiling" $rcw
# ⛔ The fixture omitted WORKERS, so the extracted chain's first line (`GATE_WHY="$(mp_reason …
# "$WORKERS")"`) never ran and `WORKERS: unbound variable` went to stderr — silently, because a
# command substitution's stderr is not captured by the assertions. Assert clean stderr, so the
# entry line is actually exercised.
mrw_err="$( { mrw 1 0 0 9999 0 9999 100 4 600 "$mem_def" >/dev/null; } 2>&1 )"
[ -z "$mrw_err" ] && rc=0 || { rc=1; echo "      mrw stderr: $mrw_err"; }
ck "the extracted gate-chain fixture runs with NO unbound-variable noise (WORKERS is set)" $rc
# ⛔ The swap gate is the other half of "the binding gates in practice", and it was UNTESTED: §7's
# default-agreement check only requires a limit to be NOT-UNSET, so setting MIN_SWAP_FREE to 0 in
# BOTH files left the suite at 284/0 while the gate became `[ "$SWFREE" -le 0 ]`, which can never
# bind. Both fixtures above pass SWTOTAL=0, which short-circuits the gate's own `[ "$SWTOTAL" -ne 0 ]`
# guard BEFORE the comparison is reached -- so the gate was never driven at all. Drive it with real
# swap, in both directions.
# ⛔ #1985: the veto now requires RAM to be tight AS WELL, so drive MEMAVAIL low with it, and the
# message must name BOTH inputs or a future reader cannot tell which fired.
[ "$(mrw 1 0 2048 100 0 100 100 4 "$swp_def" "$mem_def")" = "swap_free=100M<=min_swap_free=600M AND mem_avail=100M<=$(( ${mem_def:-512} * 2 ))M (both tight)" ] && rcw=0 || { rcw=1; echo "      got '$(mrw 1 0 2048 100 0 100 100 4 "$swp_def" "$mem_def")'"; }
ck "the swap gate FIRES when swap AND ram are both tight, and names both" $rcw
[ -z "$(mrw 1 0 2048 2000 0 9999 100 4 "$swp_def" "$mem_def")" ] && rcw=0 || rcw=1
ck "the swap gate does NOT fire when free swap is above the ceiling" $rcw
  # ⛔ THE #1985 REGRESSION, pinned. Low swap with AMPLE ram must NOT veto: a 1 GB macOS swap file
  # stays half occupied for the life of the boot, and the old arm blocked dispatch forever while the
  # box had 1.4 GB available with 20 of 20 lane slots idle. Without this case the fix can be reverted
  # to the old unconditional arm and the suite stays green.
[ -z "$(mrw 1 0 2048 100 0 1400 100 4 "$swp_def" "$mem_def")" ] && rcw=0 || { rcw=1; echo "      got '$(mrw 1 0 2048 100 0 1400 100 4 "$swp_def" "$mem_def")'" ; }
ck "the swap gate does NOT fire when swap is low but ram is ample (#1985)" $rcw
# ⛔ And with a NON-DEFAULT ceiling: the two cases above pass `$swp_def`, so they prove the gate fires
# at whatever the default is -- a regression that HARDCODED 600 into the comparison (leaving the
# plist's MIN_SWAP_FREE inert) stayed green. A ceiling the default cannot be pins the wiring itself.
[ "$(mrw 1 0 2048 650 0 100 100 4 700 "$mem_def")" = "swap_free=650M<=min_swap_free=700M AND mem_avail=100M<=$(( ${mem_def:-512} * 2 ))M (both tight)" ] && rcw=0 || { rcw=1; echo "      got '$(mrw 1 0 2048 650 0 100 100 4 700 "$mem_def")'"; }
ck "the swap gate honours a NON-DEFAULT MIN_SWAP_FREE (the ceiling is read, not hardcoded)" $rcw
[ -z "$(mrw 1 0 2048 750 0 9999 100 4 700 "$mem_def")" ] && rcw=0 || rcw=1
ck "the swap gate stays shut just above a non-default ceiling" $rcw
grep -q 'merge-priority' "$LOOP" && rc=0 || rc=1
ck "the loop implements merge-priority above the backlog threshold" $rc
grep -q '= "CONFLICTING"' "$LOOP" && rc=0 || rc=1
ck "a CONFLICTING PR is routed to the fixer, not retried as a merge" $rc
grep -q 'CONFLICTING -> fixer attempt' "$LOOP" && rc=0 || rc=1
ck "the conflict fixer is logged and capped like other fix loops" $rc
grep -q 'resolving the conflict IS the task' "$HERE/fix-one.sh" && rc=0 || rc=1
ck "the fixer prompt treats a conflict as the task" $rc
# Drive the shipped rule rather than grepping for a comment: a regression that dropped the
# 'lanes >= 1' exception or the headroom arithmetic must fail here.
{ grep -E '^is_num\(\) \{' "$LOOP"; sed -n '/^mp_reason() {/,/^}/p;/^review_slots() {/,/^}/p' "$LOOP"; } > "$TMP/mp.sh"
# ⛔ is_num FIRST in the file: mp_reason's fail-closed arm calls it, and a command that never runs
# returns non-zero, which reads as "capacity available" (fail OPEN).
if need "$TMP/mp.sh" "mp_reason()/review_slots() are extracted from the shipped loop"; then
  MERGE_PRIORITY_AT=10; MAX_REVIEW=4
  # ⛔ THIS BRANCH HAS NO TIME BOUND AND NO EVIDENCE PREAMBLE (owner ruling, 2026-10-18): the gate
  # blocks while ONE un-owned PR remains, and a stalled drain is NAMED (`[dispatch] DRAIN STALLED`)
  # rather than released. Driving it therefore needs only (count, lanes, workers) — and the cases
  # below fail if a release arm comes back, because `mp_reason 11 …` would then return empty.
  # shellcheck disable=SC1090
  . "$TMP/mp.sh"
  [ -n "$(mp_reason 11 1)" ] && rc=0 || rc=1
  ck "shipped mp_reason(): 11 open PRs with a lane running -> drain" $rc
  # ⛔ NO LANE/WORKER EXCEPTION AND NO THRESHOLD (owner ruling, 2026-10-18): 11 un-owned PRs block new
  # work whether or not a lane is running — the lane count was never the question, and the threshold
  # let the measured 25-un-owned queue through.
  [ -n "$(mp_reason 11 0)" ] && rc=0 || rc=1
  ck "shipped mp_reason(): 11 un-owned PRs with NO lane -> still drain (the lane count is irrelevant)" $rc
  [ -z "$(mp_reason 0 3)" ] && rc=0 || rc=1
  ck "shipped mp_reason(): 0 un-owned PRs -> no drain override" $rc
  [ -n "$(mp_reason 1 0)" ] && rc=0 || rc=1
  ck "shipped mp_reason(): ONE un-owned PR is enough to block new work" $rc
  [ "$(review_slots 11)" = "6" ] && rc=0 || rc=1
  ck "shipped review_slots(): backlog raises reviewer headroom to MAX_REVIEW+2" $rc
  # ⛔ THE SIZE THRESHOLD IS GONE (review R2, P3): the GATE blocks the issue path on ONE un-owned PR,
  # so the headroom follows the same predicate. 10 used to read as "below threshold = base budget";
  # keeping that would drain a 10-PR queue at the pre-change WIP.
  [ "$(review_slots 10)" = "6" ] && rc=0 || rc=1
  ck "shipped review_slots(): ANY un-owned PR raises reviewer headroom (no size threshold)" $rc
  [ "$(review_slots 0)" = "4" ] && rc=0 || rc=1
  ck "shipped review_slots(): 0 un-owned -> the base budget" $rc
  [ "$(review_slots x)" = "4" ] && rc=0 || rc=1
  ck "shipped review_slots(): a non-numeric count falls back to the base budget (not an error)" $rc
  # ⛔ The tunable must not leak into the rest of the suite: an EXPORTED MERGE_PRIORITY_AT in the
  # caller's environment survives this plain assignment, so a later §N driver inherited it and graded
  # the ambient env instead of the shipped default (#2040's finding — kept through the merge).
  unset MERGE_PRIORITY_AT MERGE_PRIORITY_MAX_AGE_MIN
fi
grep -qE 'case "\$\{PR_ST:-\}" in MERGED\|CLOSED\)' "$LOOP" && rc=0 || rc=1
ck "sweep skips CLOSED as well as MERGED" $rc

# ── 9) crash-safety bookkeeping ──────────────────────────────────────────────────
grep -q 'if wt_spawn "fix-\$PR"' "$LOOP" && rc=0 || rc=1
ck "fixer spawn is attempted before the attempt is recorded" $rc
grep -q 'PARKED after' "$LOOP" && rc=0 || rc=1
ck "reaching MAX_FIX_TRIES parks the PR instead of re-reviewing forever" $rc
grep -q 'claim_live "\$PR"' "$LOOP" && rc=0 || rc=1
ck "controller honours the claim written by the chain path" $rc

# ── 10) template / renderer placeholder parity ───────────────────────────────────
tpl="$(grep -oE '__[A-Z_]+__' "$HERE/launchd.plist.template" | sort -u)"
sedlist="$(sed -n '/^sed \\/,/launchd.plist.template/p' "$INST" | grep -oE '__[A-Z_]+__' | sed 's/^__//; s/__$//' | sed 's/^/__/; s/$/__/' | sort -u)"
[ -n "$tpl" ] && [ "$tpl" = "$sedlist" ] && rc=0 || rc=1
ck "every template placeholder is substituted by install.sh" $rc

# The placeholder parity above cannot see a renamed <key>: rename the env KEY, keep the placeholder,
# and both checks stay green while the loop reads a variable launchd never sets -- so the plist's
# environment override is silently ignored. That is the exact mechanism the `env` pass in §7 models,
# so the key names deserve their own assertion.
rck=0
for v in $_LIMITS; do
  grep -q "<key>$v</key>" "$HERE/launchd.plist.template" || { echo "      template has no <key>$v</key>"; rck=1; }
done
ck "every limit the loop reads is rendered as a plist env KEY" $rck
# Presence is not BINDING. Swapping the placeholders -- `<key>MAX_LOAD</key>` carrying
# `__MAX_LANES__` and vice versa -- keeps both names present AND keeps the placeholder SET
# identical (so the parity check above still passes), while rendering MAX_LOAD=4 / MAX_LANES=100
# into the daemon: the load gate is then effectively off against a 100 ceiling. Assert each key is
# bound to its OWN placeholder. (Mutation-verified: the swap left the suite fully green before
# this check existed.)
python3 - "$HERE/launchd.plist.template" $_LIMITS <<'PY'
import re, sys
t = open(sys.argv[1]).read()
bad = [v for v in sys.argv[2:]
       if not re.search(r"<key>%s</key>\s*<string>__%s__</string>" % (v, v), t)]
if bad:
    print("      template binds the wrong placeholder for: %s" % " ".join(bad))
sys.exit(1 if bad else 0)
PY
rcp=$?
ck "each limit's plist key is bound to its OWN placeholder (a placeholder swap is refused)" $rcp

# ── 11) no credential material shipped ───────────────────────────────────────────
rc=0
if grep -rqE 'github_pat_[A-Za-z0-9_]{20,}|ghp_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN [A-Z ]*PRIVATE KEY' "$HERE" 2>/dev/null; then rc=1; fi
ck "no credential-shaped strings in the shipped tree" $rc

# ── 12) README does not claim more than the code does ────────────────────────────
# Guards the three overclaims found in review. Match the overclaim PHRASINGS, not the words —
# §9 legitimately needs to say "not byte-identical" and §7.4 legitimately quotes the old claim.
grep -q 'so behaviour is byte-identical' "$HERE/README.md" && rc=1 || rc=0
ck "README does not claim the shipped copy is byte-identical" $rc
grep -qE 'selftest.sh. now pins every|pins every fixed defect' "$HERE/README.md" && rc=1 || rc=0
ck "README does not claim the self-test pins every defect" $rc
grep -q 'One owner per PR, per box' "$HERE/README.md" && rc=0 || rc=1
ck "README scopes the claim invariant to one box" $rc
grep -q 'serialises one box only' "$HERE/README.md" && rc=0 || rc=1
ck "README states the cross-box limitation explicitly" $rc
# The README must not state a self-test check COUNT — it drifts the moment a check is added
# (it said 29 while the file had 42, then 46/46 while the file ran 57). The guard matches the
# PHRASINGS that actually drifted and is proved non-vacuous against a fixture of pre-fix text.
OVERC='[0-9]+ checks|[0-9]+ of its checks|measured [0-9]+/[0-9]+|[0-9]+/[0-9]+ shipped'
grep -qE "$OVERC" "$HERE/README.md" && rc=1 || rc=0
ck "README states no self-test check count that can drift" $rc
cat > "$TMP/overclaim.md" <<'MD'
review of this very file, and 19 of its checks fail when it is dropped into the
| measured 7/30 on the pre-fix tree vs 46/46 shipped |
MD
grep -qE "$OVERC" "$TMP/overclaim.md" && rc=0 || rc=1
ck "the drift guard matches the pre-fix phrasings (non-vacuous)" $rc
# The required-check set is PER-REPO now (agent-infra#1764): resolved from the target repo's
# branch protection, with FALLBACK_REQ as the fail-closed last resort. A fixed count in the README
# would be wrong for one of the two repos, so the guard is INVERTED: the README must DESCRIBE the
# per-repo resolution, the shipped fallback must be non-empty (an unreadable endpoint must not
# become an empty required set), and the README must not spell a fixed count beside it.
nreq="$(sed -n 's/^FALLBACK_REQ="\(.*\)"$/\1/p' "$HERE/repo-authority.sh" | tr ' ' '\n' | grep -c .)"
[ "$nreq" -ge 1 ] && rc=0 || { rc=1; echo "      fallback names: $nreq"; }
ck "the shipped FALLBACK_REQ is NON-EMPTY ($nreq names — the unreadable-protection arm fails CLOSED)" $rc
grep -q 'branch protection' "$HERE/README.md" && rc=0 || rc=1
ck "README documents the per-repo required-check resolution" $rc
numerals='([0-9]+|one|two|three|four|five|six|seven|eight|nine|ten) required check'
bad="$(grep -oE "$numerals" "$HERE/README.md" | head -1)"
[ -z "$bad" ] && rc=0 || { rc=1; echo "      README claims '$bad'"; }
ck "README states no fixed required-check count (the set is per-repo now)" $rc
bad="$(printf 'read the 7 required checks\nand the eight required check names\n' | grep -oE "$numerals" | head -1)"
[ -n "$bad" ] && rc=0 || rc=1
ck "non-vacuity: the count guard still flags a fixed count of required checks (saw '$bad')" $rc
grep -q 'selftest.sh' "$HERE/README.md" && rc=0 || rc=1
ck "README points at the self-test" $rc

# ── 13) a hostile branch name cannot reach a shell ───────────────────────────────
# git PERMITS ' ; $ ` & | ( ) { } " < > # in a ref name — only spaces are forbidden, and ${IFS}
# supplies those. The controller embedded headRefName inside a tmux `sh -c` string, so a fork PR on
# branch `fix/x';touch${IFS}/tmp/VULN;#` got arbitrary command execution on the host that holds the
# merge key. This was reproduced end-to-end before the fix.
sed -n '/^safe_ref() {/,/^}/p' "$LOOP" > "$TMP/saferef.sh"
if need "$TMP/saferef.sh" "safe_ref() is extracted from the shipped orch-loop.sh"; then
  REPO="$HERE/../.."
  # shellcheck disable=SC1090
  . "$TMP/saferef.sh"
  HOSTILE="fix/x';touch\${IFS}/tmp/VULN;#"
  safe_ref "$HOSTILE" && rc=1 || rc=0
  ck "shipped safe_ref() rejects a hostile branch name" $rc
  safe_ref "fix/8246-orchestrator-harness-handover" && rc=0 || rc=1
  ck "shipped safe_ref() accepts a normal branch name" $rc
  safe_ref "feat/1234-tm" && rc=0 || rc=1
  ck "shipped safe_ref() accepts a generated branch name" $rc
fi
grep -q '^is_num() {' "$LOOP" && rc=0 || rc=1
ck "the shipped loop defines is_num() for PR ids" $rc
# ⛔ ONE PREDICATE, EVERY SHIPPED COPY — AND NO LENIENT FIFTH (P3, third review round, 2026-10-14).
# selftest.sh carried its OWN lenient `is_num` (`''|*[!0-9]*`, which ACCEPTS `08`) beside the
# tightened copies in orch-loop.sh / merge-one.sh / fix-one.sh / install.sh. It was unused — every
# driver in this file extracts and sources the SHIPPED predicate it is testing, not this one — so it
# was a documentation hazard rather than a live defect. But it contradicted "all copies agree", and
# the next reader to copy the nearest definition would take the lax form. The lenient copy is DELETED
# and this check requires the tight form in every copy that exists, including this file's. Restoring
# the lenient definition anywhere is RED.
_tight='0*) return 1'
_lax=0; _ndefs=0
for _f in "$LOOP" "$MERGE" "$HERE/fix-one.sh" "$INST" "$HERE/selftest.sh"; do
  _found=0
  while IFS= read -r _d; do
    [ -n "$_d" ] || continue
    _found=1
    case "$_d" in *"$_tight"*) ;; *) _lax=1; echo "      $_f has a lenient is_num(): $_d";; esac
  # DEFINITIONS only (`^is_num() {`) — a bare `is_num() {` also appears inside this file's own
  # extraction greps, and matching those would flag every one of them as a lenient copy.
  done < <(grep -E '^[[:space:]]*is_num\(\) \{' "$_f" 2>/dev/null)
  [ "$_found" = "1" ] && _ndefs=$((_ndefs+1))
done
[ "$_lax" = "0" ] && rc=0 || rc=1
ck "every is_num() copy in the tree (including selftest's) rejects leading zeros and accepts 0" $rc
[ "$_ndefs" = "4" ] && rc=0 || { rc=1; echo "      is_num() is defined in $_ndefs of the 4 shipped files that need it"; }
ck "the four SHIPPED files each still define is_num() (a silently dropped copy is caught)" $rc
grep -q -- "--argv" "$LOOP" && rc=0 || rc=1
ck "worker launches pass args via --argv, not string interpolation" $rc
grep -qE "'\\\$OR' \\\$PR '\\\$BR'" "$LOOP" && rc=1 || rc=0
ck "no \$OR/\$PR/\$BR interpolation remains in the spawn commands" $rc
# The retired tree ships next to the live scripts and is executable, so an unsafe interpolation
# there is a re-armable P0 for anyone who reuses it. It must be annotated as such.
grep -q 'RETIRED: unsafe interpolation' "$HERE/retired/auto-loop.sh" && rc=0 || rc=1
ck "the retired copy's unsafe interpolation is annotated in place" $rc
grep -q 'Prefer the live scripts' "$HERE/retired/auto-loop.sh" && rc=0 || rc=1
ck "the retired copy's banner warns against reuse" $rc

# ── 14) the controller does not treat a stale claim as in-flight ────────────────
# ⛔ BOTH FUNCTIONS: claim_live is the SPAWN GUARD and delegates its lease arm to claim_lease_live
# (review R2, P1 split them so ownership cannot inherit the guard's loose local-lock test).
{ sed -n '/^claim_live() {/,/^}/p' "$LOOP"; sed -n '/^claim_lease_live() {/,/^}/p' "$LOOP"; } > "$TMP/claimlive.sh"
if need "$TMP/claimlive.sh" "claim_live() is extracted from the shipped orch-loop.sh"; then
  mkdir -p "$TMP/CL/state"
  O="$TMP/CL"
  # ⛔ THE VERDICT ITSELF IS SOURCED FROM claims.sh, NOT EXTRACTED (agent-infra#2466). The lease
  # polarity and the orphan rule live beside the writer (`_lease_is_live`, `claim_orphan_reason`),
  # and `claim_lease_live` is now a three-line mapping onto `claim_snapshot_verdict`. Extracting the
  # mapper without the verdict would let this suite pass on a fixture whose verdict the shipped
  # reader no longer produces — the drift class this section exists to catch.
  CLAIM_REPO="$TMP/CL"
  # shellcheck disable=SC1090
  . "$HERE/claims.sh"
  # shellcheck disable=SC1090
  . "$TMP/claimlive.sh"
  printf '%s' "$$" > "$O/state/mergeclaim-1.lock"
  claim_live 1 && rc=0 || rc=1
  ck "shipped claim_live(): a live owner counts as in flight" $rc
  printf '%s' "999999" > "$O/state/mergeclaim-2.lock"
  claim_live 2 && rc=1 || rc=0
  ck "shipped claim_live(): a dead owner is not in flight" $rc
  [ -f "$O/state/mergeclaim-2.lock" ] && rc=1 || rc=0
  ck "shipped claim_live(): the stale claim file is removed" $rc
  # ⛔ A FOREIGN OVERSIZED (>= 2**63) LEASE (P2, fourth review round, 2026-10-14). claim_acquire()
  # treats such a lease as unparseable => LIVE (claims.sh's 18-digit bound; test-claims.sh §P3e seeds
  # the same value), but claim_live() read the SAME datum with a bare `[ "$now" -le "$until" ]`,
  # which ERRORS at 2**63 and — read as false — reported it DEAD. The two readers then disagreed
  # forever: the controller reached the spawn branch EVERY cycle, fix-one.sh was refused by
  # claim_acquire, wrote fixbail-<pr>-<head>, and refund_bailed_fixer deleted that marker AND
  # `parked-<pr>` next cycle — so the cap never tripped and the PR was never parked. One refused
  # spawn + 1 GitHub call + 3 remote round trips per cycle, indefinitely, on a PR no box could work.
  # Drive the snapshot file the function actually reads, with a lease whose ONLY defect is magnitude.
  CLSHA=deadbeefcafebabe0123456789abcdef01234567
  printf 'refs/claims/3-%s\tforeignbox\t9223372036854775808\n' "${CLSHA:0:12}" > "$O/state/claims-snapshot"
  # The shipped CONFLICTING arm is `elif claim_live "$PR" "$HEAD" || sess "fix-$PR" || sess "merge-$PR"`;
  # `false` stands in for a `sess` that finds no local worker session, so `spawn=yes` is exactly the
  # fall-through that runs `tmux … fix-one.sh`.
  spawn=no
  if claim_live 3 "$CLSHA" || false; then :; else spawn=yes; fi
  claim_live 3 "$CLSHA" && rc=0 || rc=1
  ck "shipped claim_live(): an oversized (>=2**63) lease reports LIVE, not dead" $rc
  [ "$spawn" = "no" ] && rc=0 || rc=1
  ck "shipped claim_live(): no spawn is attempted for an oversized-lease claim" $rc
  # ⛔ THE `0` SENTINEL IS NOT THE SAME AS ABSENT (P2, fifth review round, 2026-10-14). claims.sh
  # documents `0` as "a claim exists whose lease is UNREADABLE" and treats it as LIVE (claim_acquire's
  # `[ -z "$held_until" ] || [ "$held_until" = "0" ]`; claim_prune keeps it via `[ "$until" != "0" ]`).
  # `_lease_of` collapses a negative lease to the same `0` (its `[0-9]*` cannot match the minus sign),
  # so `lease_until=-5` ARRIVES HERE AS `0`. claim_live used to read that `0` as DEAD while
  # claim_acquire read the same datum as LIVE — the SAME disagreement as the oversized class above,
  # with the same consequence (refund_bailed_fixer un-parks the PR every cycle, so the cap never
  # trips). Drive the snapshot entry the function actually reads.
  printf 'refs/claims/5-%s\tforeignbox\t0\n' "${CLSHA:0:12}" > "$O/state/claims-snapshot"
  spawn=no
  if claim_live 5 "$CLSHA" || false; then :; else spawn=yes; fi
  claim_live 5 "$CLSHA" && rc=0 || rc=1
  ck "shipped claim_live(): an unreadable lease (0) reports LIVE, not dead" $rc
  [ "$spawn" = "no" ] && rc=0 || rc=1
  ck "shipped claim_live(): no spawn is attempted for an unreadable-lease claim" $rc
  # The literal negative too — the form _lease_of collapses, and the one claim_prune reads as "keep"
  # (never as reaped). The reader must AGREE on this row as well.
  printf 'refs/claims/6-%s\tforeignbox\t-5\n' "${CLSHA:0:12}" > "$O/state/claims-snapshot"
  claim_live 6 "$CLSHA" && rc=0 || rc=1
  ck "shipped claim_live(): a negative lease reports LIVE, matching claim_acquire/claim_prune" $rc
  # Non-vacuity: an entry ABSENT from the snapshot is still NOT live. Without this the fix could be
  # "return 0 always" and every assertion above would still pass.
  printf 'refs/claims/999-%s\tforeignbox\t1799999999\n' "${CLSHA:0:12}" > "$O/state/claims-snapshot"
  claim_live 6 "$CLSHA" && rc=1 || rc=0
  ck "shipped claim_live(): a PR absent from the snapshot is NOT live (the sentinel fix is not vacuous)" $rc
fi

# ── 15) a BAILED fixer refunds its attempt and restores the findings marker ─────
# fix-one.sh exits 0 when the cross-box CAS refuses it, having done NO work. The controller booked
# the attempt at spawn and (on the reviewer-findings arm) deleted the findings marker there, so
# before this refund three refusals PARKED a PR no fixer ever touched, with the reviewer's findings
# gone. The function is EXTRACTED and DRIVEN, not grepped (P2, second review round, 2026-10-14).
{ grep -m1 '^is_num() {' "$LOOP"; sed -n '/^refund_bailed_fixer() {/,/^}/p' "$LOOP"; } > "$TMP/refund-all.sh"
if need "$TMP/refund-all.sh" "refund_bailed_fixer() and is_num() are extracted from the shipped orch-loop.sh"; then
  mkdir -p "$TMP/RB/state"; O="$TMP/RB"; LOG="$TMP/RB/loop.log"; : > "$LOG"
  # shellcheck disable=SC1090
  . "$TMP/refund-all.sh"
  # (a) reviewer-findings arm: booked to 2, findings marker deleted at spawn, bail recorded.
  # ⛔ THE SPEND RECORD IS PART OF THE FIXTURE (review round 4, P3). `refund_bailed_fixer … 1` now
  # restores only what the dispatch ACTUALLY TOOK, and `fixspend-<PR>-<head>` is the record of that
  # take — written by the one spawn site that deletes a findings marker. A fixture WITHOUT it drove
  # the "another arm bailed" case by accident, so this arm asserted the wrong contract (selftest went
  # RED at round 5 while test-gates stayed green). The spend file is now seeded here and asserted
  # CONSUMED below; the no-spend contract is driven separately in (a2).
  rm -f "$O/state/needsfix-77-abc" "$O/state/fixspend-77-abc"
  echo 2 > "$O/state/fixcount-77"; : > "$O/state/fixbail-77-abc"; : > "$O/state/parked-77"
  : > "$O/state/fixspend-77-abc"
  refund_bailed_fixer 77 abc 1
  if [ "$(cat "$O/state/fixcount-77" 2>/dev/null)" = "1" ] && [ ! -f "$O/state/fixbail-77-abc" ] \
     && [ -f "$O/state/needsfix-77-abc" ] && [ ! -f "$O/state/parked-77" ] \
     && [ ! -f "$O/state/fixspend-77-abc" ]; then rc=0
  else rc=1; echo "      fix=$(cat "$O/state/fixcount-77" 2>/dev/null) bail=$([ -f "$O/state/fixbail-77-abc" ] && echo yes || echo no) findings=$([ -f "$O/state/needsfix-77-abc" ] && echo yes || echo no) parked=$([ -f "$O/state/parked-77" ] && echo yes || echo no) spend=$([ -f "$O/state/fixspend-77-abc" ] && echo yes || echo no)"; fi
  ck "a bailed fixer refunds the attempt AND restores the findings marker (spend consumed)" $rc
  # (a2) ⛔ A BAIL WITH NO SPEND MUST NOT MANUFACTURE A FINDINGS MARKER (review round 4, P3). The
  # bail may have been written by the CI-red or CONFLICTING arm, which never delete a findings marker;
  # refunded on a later gate-red cycle, an unconditional touch invented a fixer authorisation for a
  # head no reviewer reported on. The attempt is still refunded — only the marker is withheld.
  rm -f "$O/state/needsfix-78-abc" "$O/state/fixspend-78-abc"
  echo 2 > "$O/state/fixcount-78"; : > "$O/state/fixbail-78-abc"
  refund_bailed_fixer 78 abc 1
  if [ "$(cat "$O/state/fixcount-78" 2>/dev/null)" = "1" ] && [ ! -f "$O/state/fixbail-78-abc" ] \
     && [ ! -f "$O/state/needsfix-78-abc" ]; then rc=0
  else rc=1; echo "      fix=$(cat "$O/state/fixcount-78" 2>/dev/null) bail=$([ -f "$O/state/fixbail-78-abc" ] && echo yes || echo no) findings=$([ -f "$O/state/needsfix-78-abc" ] && echo yes || echo no)  <- a findings marker was MANUFACTURED"; fi
  ck "a bail that consumed NO findings marker is refunded WITHOUT manufacturing one" $rc
  # (b) CI-red / CONFLICTING arm: no findings marker was deleted, so NONE may be invented.
  rm -f "$O/state/needsfix-88-abc" "$O/state/parked-88"; echo 1 > "$O/state/fixcount-88"; : > "$O/state/fixbail-88-abc"
  refund_bailed_fixer 88 abc 0
  [ "$(cat "$O/state/fixcount-88" 2>/dev/null)" = "0" ] && [ ! -f "$O/state/needsfix-88-abc" ] && rc=0 || rc=1
  ck "a bail on an arm that deleted no findings marker does not invent one" $rc
  # (c) NO bail marker -> nothing to refund. Non-vacuity: the refund is conditional on a real bail.
  echo 3 > "$O/state/fixcount-99"; refund_bailed_fixer 99 abc 1
  [ "$(cat "$O/state/fixcount-99" 2>/dev/null)" = "3" ] && [ ! -f "$O/state/needsfix-99-abc" ] && rc=0 || rc=1
  ck "no bail marker means no refund (the refund is not unconditional)" $rc
  # (d) a leading-zero fixcount must not reach `$(( 08 ))` — is_num normalises it first.
  echo 08 > "$O/state/fixcount-55"; : > "$O/state/fixbail-55-abc"; refund_bailed_fixer 55 abc 0
  [ "$(cat "$O/state/fixcount-55" 2>/dev/null)" = "0" ] && rc=0 || { rc=1; echo "      got '$(cat "$O/state/fixcount-55" 2>/dev/null)'"; }
  ck "a leading-zero fixcount is normalised by is_num (no arithmetic abort)" $rc
  # (e) ⛔ THE ORDERING AT THE THIRD CALL SITE, DRIVEN (P2, third review round, 2026-10-14). The
  # CONFLICTING arm and the ai-review-gate arm read the count AFTER the refund; the CI-red arm read
  # it BEFORE, so the decrement was immediately overwritten by `NFC2 + 1` and a bailed fixer still
  # consumed an attempt. Three no-op cross-box refusals PARKED the PR as needs-a-human. The block
  # below extracts the THREE statements of the SHIPPED CI-red arm IN FILE ORDER and runs them on a
  # fixture: start=3 with a bail marker must leave NFC2=2 (refunded, then read) — not 3. Moving the
  # read back above the refund is RED, and the cap predicate on the shipped NFC2 is then false, so
  # the arm spawns instead of parking.
  awk 'index($0,"# CI-red arm (agent-infra")>0{b=1}
       b&&index($0,"if grep -q python-ci-gate")>0{b=0}
       b' "$LOOP" \
    | grep -E '^ *(NFC2=|is_num "\$NFC2"|refund_bailed_fixer "\$PR")' > "$TMP/ci-arm-seq.sh"
  if need "$TMP/ci-arm-seq.sh" "the CI-red arm's refund+read sequence is extracted from the shipped loop"; then
    rm -f "$O/state/fixcount-231" "$O/state/fixbail-231-abc" "$O/state/parked-231"
    echo 3 > "$O/state/fixcount-231"; : > "$O/state/fixbail-231-abc"; : > "$O/state/parked-231"
    PR=231; HEAD_N=abc; MAX_FIX_TRIES=3; NFC2=unset
    # shellcheck disable=SC1090
    eval "$(cat "$TMP/ci-arm-seq.sh")"
    if [ "${NFC2:-x}" = "2" ] && [ "$(cat "$O/state/fixcount-231" 2>/dev/null)" = "2" ] \
       && [ "${NFC2:-0}" -lt "${MAX_FIX_TRIES:-3}" ]; then rc=0
    else rc=1; echo "      CI-red arm: NFC2='${NFC2:-}' fixcount='$(cat "$O/state/fixcount-231" 2>/dev/null)' parked=$([ -f "$O/state/parked-231" ] && echo yes || echo no)"; fi
    ck "the CI-red arm refunds BEFORE reading the count (start=3 -> NFC2=2 < cap, respawn not PARK)" $rc
  fi
fi

# The CI-red arm is DERIVED from the repo's required set now (#1764): the pre-fix form named
# tortoise's five checks as a literal, so a red `pipeline-compliance` on agent-infra matched
# nothing and the PR sat red with no worker. Pin BOTH halves — the literal is gone AND the arm is
# driven by $REQ — so a revert to a name list, or a broken derivation, is RED.
grep -qE "'docs\|test-isolation\|license-surface\|legal-e2e\|pricing-artifact'" "$LOOP" && rc=1 || rc=0
ck "the CI-red arm no longer names tortoise's checks as a literal" $rc
grep -q 'CI_RED=' "$LOOP" && rc=0 || rc=1
ck "the CI-red arm derives its red name from the required set" $rc
# The derivation is EXTRACTED and DRIVEN against both repo shapes: a red pipeline-compliance must
# be recognised as a required name (fixer), and the review gate must be excluded (it has its own
# arm), on agent-infra's set and on tortoise's.
sed -n '/^        RERUN_RED=/,/^        set +f; IFS="\$_redifs"$/p' "$LOOP" > "$TMP/ci-red-classify.sh"
if need "$TMP/ci-red-classify.sh" "the CI-red derivation is extracted from the shipped orch-loop.sh"; then
  REQ='pipeline-compliance'; REVIEW_GATE='ai-review-gate'; V='FAILED:pipeline-compliance'
  # shellcheck disable=SC1090
  . "$TMP/ci-red-classify.sh"
  [ "${CI_RED:-}" = "pipeline-compliance" ] && rc=0 || { rc=1; echo "      CI_RED='${CI_RED:-}' req=$REQ"; }
  ck "CI-red derivation: a red agent-infra required check is recognised (no name list needed)" $rc
  REQ='pipeline-compliance'; V='FAILED:ci / lint'; CI_RED=""
  # shellcheck disable=SC1090
  . "$TMP/ci-red-classify.sh"
  [ -z "${CI_RED:-}" ] && rc=0 || { rc=1; echo "      CI_RED='${CI_RED:-}' (non-required must not route)"; }
  ck "CI-red derivation: a non-required red does not route to the fixer" $rc
  REQ='ai-review-gate python-ci-gate docs test-isolation license-surface legal-e2e pricing-artifact'
  V='FAILED:ai-review-gate,docs'; CI_RED=""
  # shellcheck disable=SC1090
  . "$TMP/ci-red-classify.sh"
  [ "${CI_RED:-}" = "docs" ] && rc=0 || { rc=1; echo "      CI_RED='${CI_RED:-}' (review gate must be excluded)"; }
  ck "CI-red derivation: the review gate is excluded (it has its own arm), tortoise's docs still routes" $rc
  # Review P2, round 1 — the RERUN carve-out: python-ci-gate is owned by the rerun block at the
  # bottom of the case, exactly as in the pre-#1764 arm, so a flaky CI lane must NOT route to the
  # code-pushing fixer (it would also double-fire: rerun AND fixer).
  REQ='ai-review-gate python-ci-gate docs test-isolation license-surface legal-e2e pricing-artifact'
  V='FAILED:python-ci-gate'; CI_RED=""
  # shellcheck disable=SC1090
  . "$TMP/ci-red-classify.sh"
  [ -z "${CI_RED:-}" ] && rc=0 || { rc=1; echo "      CI_RED='${CI_RED:-}' (python-ci-gate must stay with the rerun block, not the fixer)"; }
  ck "CI-red derivation: python-ci-gate is EXCLUDED (the rerun block owns it — the pre-#1764 carve-out is preserved)" $rc
fi
grep -q 'CI-red (.*fixer attempt' "$LOOP" && rc=0 || rc=1
ck "the CI-red fixer is logged and capped like other fix loops" $rc
grep -q 'FAILING_CHECKS=' "$HERE/fix-one.sh" && rc=0 || rc=1
ck "the fixer is given the failing check" $rc
grep -q 'failing.txt' "$HERE/fix-one.sh" && rc=0 || rc=1
ck "the fixer is given the failing CI log" $rc
# ── a fake worker SURFACE, shared by the two reaper drives (§15 and §19) ────────────────────
# THE CENSUS THE SHIPPED REAPER WALKS IS THE LAUNCHER'S, NOT `tmux ls` (measured 2026-10-20): on a
# cell its workers are DURABLE TERMINALS, so a reaper that still looked for tmux sessions matched
# NOTHING and every hung worker held its slot until a human noticed. This stub therefore serves BOTH
# kinds at once — `merge-999` a stale durable terminal, `merge-100` a fresh one, `fix-77` a stale
# LEGACY tmux session — so each drive proves the mixed table, not one half of it. CLOSED/KILLED are
# how a drive observes the decision (empty = nothing was touched).
cat > "$TMP/wtstub.sh" <<'SH'
CLOSED=""; KILLED=""
wt_fake_tree() {
  _ws=""; _sc=""; _tb=""; _tm=""
  for _n in merge-999 merge-100; do
    case "$CLOSED" in *"term_$_n"*) continue ;; esac
    _ws="$_ws${_ws:+,}{\"id\":\"ws_$_n\",\"name\":\"wt-$_n\"}"
    _sc="$_sc${_sc:+,}{\"id\":\"s_$_n\",\"workspace_id\":\"ws_$_n\",\"layout\":{\"root\":{\"tab_ids\":[\"t_$_n\"]}}}"
    _tb="$_tb${_tb:+,}{\"id\":\"t_$_n\",\"content_id\":\"term_$_n\"}"
    _tm="$_tm${_tm:+,}{\"id\":\"term_$_n\",\"running\":true}"
  done
  printf '{"workspaces":[%s],"screens":[%s],"tabs":[%s],"terminals":[%s]}\n' "$_ws" "$_sc" "$_tb" "$_tm"
}
cmux() {
  case "${1:-}" in
    tree) wt_fake_tree ;;
    terminal) [ "${2:-}" = "close" ] && CLOSED="$CLOSED $3" ;;
    workspace) : ;;
  esac
  return 0
}
tmux() {
  case "${1:-}" in
    ls) for _s in fix-77; do case "$KILLED" in *"$_s"*) continue ;; esac; printf '%s\n' "$_s"; done ;;
    list-panes) echo 4242 ;;
    kill-session) KILLED="$KILLED ${3#=}" ;;
  esac
  return 0
}
kill() { :; }
SH
# ── 15) a hung worker cannot hold a concurrency slot forever ────────────────────
# `pi -p` has no internal timeout. A hung reviewer occupied a merge slot for 9 hours on
# 2026-10-12 while the caps (which count SESSIONS) reported the slot as busy.
grep -q '^  reap_stale_workers$' "$LOOP" && rc=0 || rc=1
ck "the reaper runs every cycle" $rc
sed -n '/^reap_stale_workers() {/,/^}/p' "$LOOP" > "$TMP/reapw-body.sh"
# The reaper now delegates the mtime probe to the shipped portable helper (#1702), so its unit is
# the helper PLUS the reaper. Extracting the reaper alone leaves file_mtime_epoch undefined and the
# reaper silently skips every session (`command not found` -> the `|| continue` guard) — which is
# exactly what this check caught when the helper was introduced.
{ grep -m1 '^is_num() {' "$LOOP"; sed -n '/^file_mtime_epoch() {/,/^}/p' "$LOOP"; cat "$TMP/reapw-body.sh"; } > "$TMP/reapw.sh"
if need "$TMP/reapw.sh" "reap_stale_workers() and its file_mtime_epoch() helper are extracted from the shipped loop"; then
  mkdir -p "$TMP/RW/logs" "$TMP/RW/state"
  : > "$TMP/RW/logs/merge-999.log"; touch -t 202601010000 "$TMP/RW/logs/merge-999.log"
  : > "$TMP/RW/logs/fix-77.log";   touch -t 202601010000 "$TMP/RW/logs/fix-77.log"
  : > "$TMP/RW/fresh.log"
  # The launcher's own records: two durable terminals (one stale, one fresh) and one LEGACY tmux
  # worker. All three answers come from the shipped census, which is the point — the two kinds share
  # one table, so a reaper that still looked for tmux sessions would reap neither terminal.
  printf 'kind=terminal\nid=term_merge-999\nworkspace=ws_merge-999\n' > "$TMP/RW/state/worker-merge-999"
  printf 'kind=terminal\nid=term_merge-100\nworkspace=ws_merge-100\n' > "$TMP/RW/state/worker-merge-100"
  printf 'kind=tmux\ncwd=/tmp\n' > "$TMP/RW/state/worker-fix-77"
  # shellcheck disable=SC1090
  . "$TMP/wtstub.sh"
  LOG="$TMP/RW/rw.log"; O="$TMP/RW"; WT_DIR="$TMP/RW/state"; STALE_MIN=1; WT_TABLE_TTL=0
  # shellcheck disable=SC1090
  . "$HERE/worker-terminal.sh"
  # shellcheck disable=SC1090
  . "$TMP/reapw.sh"
  reap_stale_workers
  case "$CLOSED" in *term_merge-999*) rc=0 ;; *) rc=1; echo "      closed: [$CLOSED]";; esac
  ck "shipped reaper closes the DURABLE TERMINAL whose log has gone stale" $rc
  case "$CLOSED" in *term_merge-100*) rc=1 ;; *) rc=0 ;; esac
  ck "shipped reaper leaves the FRESH durable terminal alone" $rc
  case "$KILLED" in *fix-77*) rc=0 ;; *) rc=1; echo "      killed: [$KILLED]";; esac
  ck "shipped reaper still reaps a LEGACY tmux worker out of the same census" $rc
  grep -q 'reap-worker' "$LOG" && rc=0 || rc=1
  ck "the reaper logs what it killed" $rc
  # Exact-match targets: a prefix match would let the reaper kill a DIFFERENT, healthy session
  # if the stale one exited between the snapshot and the kill. The tmux branch moved with the
  # launcher, so this pin follows it to the file that now owns it.
  grep -q 'kill-session -t "=\$name"' "$HERE/worker-terminal.sh" && rc=0 || rc=1
  ck "the reaper uses exact session targets (=name), not prefix matches" $rc
  grep -q 'list-panes -t "=\$name"' "$HERE/worker-terminal.sh" && rc=0 || rc=1
  ck "the reaper resolves the pane pid with an exact target" $rc
  unset -f cmux tmux kill
fi
# the agent invocation is wall-clock bounded, portably (macOS has no timeout/gtimeout)
sed -n '/^run_agent() {/,/^}/p' "$MERGE" > "$TMP/runagent.sh"
if need "$TMP/runagent.sh" "run_agent() is extracted from the shipped merge-one.sh"; then
  # NOTE: the heredoc must EXPAND $TMP (unquoted) while leaving the runtime substitutions for the
  # script itself. A quoted heredoc left the source path literal, so run_agent never got defined and
  # the check passed on "command not found" — the exact vacuity this file exists to prevent.
  cat > "$TMP/ra.sh" <<SH
pi() { sleep 60; }
. "$TMP/runagent.sh"
# ⛔ THE PROMPT IS A REAL BRIEF, NOT /dev/null (agent-infra#2258). run_agent now refuses a brief with
# no research contract (80) BEFORE it spawns, so this arm's `/dev/null` would make the shipped
# run_agent return 80 without ever launching `pi` — and the assertion below ("it ran, and was cut off
# at the wall limit") would fail for a reason that has nothing to do with the timeout it exists to
# test. Rendering the canonical block keeps the fixture HONEST: the function under test still gets a
# brief of the shape a real dispatch carries.
brief_gate_sh="$HERE/brief-gate.sh"; bash "\$brief_gate_sh" --section reviewer > "$TMP/ra-brief.txt"
start=\$(date +%s); run_agent 2 "$TMP/ra.log" "$TMP/ra-brief.txt"; rc=\$?; end=\$(date +%s)
echo "\$((end-start)) \$rc"
SH
  ra="$(bash "$TMP/ra.sh" 2>/dev/null | tail -1)"
  set -- $ra
  # must have actually run (a real abort, non-zero rc), and been cut off well before the 60s sleep
  ran=0; grep -q 'wall_limit=' "$TMP/ra.log" 2>/dev/null && ran=1
  if [ "$ran" = "1" ] && [ "${1:-0}" -ge 1 ] && [ "${1:-99}" -lt 30 ] && [ "${2:-0}" -ne 0 ]; then rc=0; else rc=1; fi
  ck "shipped run_agent() kills a hung agent at the wall limit (elapsed=${1:-?}s rc=${2:-?} ran=$ran)" $rc
fi

# ── 16) a FAILED open-PR count is never read as zero ─────────────────────────────
# The pre-fix line was OPEN_N="$(gh pr list … 2>/dev/null)"; : "${OPEN_N:=0}" — rc and stderr
# were discarded and the empty result was coerced to 0, so one transient `TLS handshake timeout`
# turned a 25-open-PR queue into `open=0 -> OWN`, dropping the BROAD drain, the reviewer headroom
# and the merge-priority gate at once. Drive the SHIPPED function (extracted, not re-implemented)
# with a stubbed gh, and pin the failure path, the sticky fallback and the success write.
unset -f gh pi uv tmux 2>/dev/null || true   # an exported function would shadow the gh stub below
sed -n '/^open_pr_count() {/,/^}/p' "$LOOP" > "$TMP/opencount.sh"
if need "$TMP/opencount.sh" "open_pr_count() is extracted from the shipped orch-loop.sh"; then
  OC="$TMP/opencount"; mkdir -p "$OC/state"
  { echo 'set -u'; grep -m1 '^is_num() {' "$LOOP"; cat "$TMP/opencount.sh"; echo 'open_pr_count'; } > "$OC/drive.sh"
  # Driver must be non-vacuous: it parses and really defines the shipped function.
  bash -n "$OC/drive.sh" && rc=0 || rc=1
  ck "the open-PR-count driver parses" $rc
  # (a) gh FAILS: TLS handshake timeout on stderr, empty stdout, rc 1
  cat > "$OC/gh" <<'SH'
#!/bin/bash
echo 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout' >&2
exit 1
SH
  chmod +x "$OC/gh"; rm -f "$OC/state/last-open-n"; LOG="$OC/log"; : > "$LOG"
  n="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" bash "$OC/drive.sh" )"
  [ "$n" != "0" ] && [ -n "$n" ] && rc=0 || { rc=1; echo "      failed gh produced '$n'"; }
  ck "a failed open-PR count is NOT zero (got '$n')" $rc
  [ "$n" = "26" ] && rc=0 || { rc=1; echo "      got '$n'"; }
  ck "a first-ever failure assumes 26 (above the 25 default, BROAD, resumes the drain)" $rc
  grep -q 'open=UNKNOWN rc=1' "$LOG" && rc=0 || { rc=1; echo "      log: $(cat "$LOG")"; }
  ck "a failed open-PR count logs an UNKNOWN diagnostic naming the rc" $rc
  grep -q 'TLS handshake timeout' "$LOG" && rc=0 || { rc=1; echo "      log: $(cat "$LOG")"; }
  ck "the diagnostic keeps gh's stderr instead of discarding it" $rc
  # (b) sticky: a later failure reuses the last good count, never resets to 0
  printf '25\n' > "$OC/state/last-open-n"; : > "$LOG"
  n="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" bash "$OC/drive.sh" )"
  [ "$n" = "25" ] && rc=0 || { rc=1; echo "      sticky produced '$n'"; }
  ck "a later failure reuses the sticky last-known count (25)" $rc
  # (b2) a sticky 0 must NOT be reused: a DRAINED queue is the dangerous case (PRs arrive, then one
  # transient failure) and 0 drives OWN / no headroom / no merge-priority — the exact pre-fix bug.
  printf '0\n' > "$OC/state/last-open-n"; : > "$LOG"
  n="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" bash "$OC/drive.sh" )"
  [ "$n" != "0" ] && [ -n "$n" ] && rc=0 || { rc=1; echo "      sticky-0 produced '$n'"; }
  ck "a sticky last-known of 0 is not reused (got '$n')" $rc
  [ "$n" = "26" ] && rc=0 || { rc=1; echo "      got '$n'"; }
  ck "a sticky 0 falls back to 26 (BROAD)" $rc
  # (b3) the fallback must clear the SCOPE threshold too, not just the merge-priority tunable:
  # max(MERGE_PRIORITY_AT, 10) + 1. Keying it to the tunable alone left a below-default tunable in
  # OWN — the unsafe direction — on a failed count.
  _mp="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" MERGE_PRIORITY_AT=4 bash "$OC/drive.sh" )"
  [ "$_mp" = "11" ] && rc=0 || { rc=1; echo "      MERGE_PRIORITY_AT=4 produced '$_mp' (expected 11)"; }
  ck "a below-default MERGE_PRIORITY_AT (4) falls back to 11, above the scope threshold" $rc
  _mp="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" MERGE_PRIORITY_AT=15 bash "$OC/drive.sh" )"
  [ "$_mp" = "16" ] && rc=0 || { rc=1; echo "      MERGE_PRIORITY_AT=15 produced '$_mp' (expected 16)"; }
  ck "an above-default MERGE_PRIORITY_AT (15) falls back to 16, above the tunable" $rc
  # (b4) UNIT coverage of open_pr_count's base-10 normalisation, reached only with the tunable guard
  # BYPASSED — which is exactly what this driver does (it sources is_num + open_pr_count, not the
  # loop's is_limit coercion). ⚠️ In the SHIPPED loop the guard runs FIRST: is_num rejects leading
  # zeros, so `MERGE_PRIORITY_AT=010` is coerced to the default (25) and the real fallback is 26 —
  # asserted directly above. Do not read this case as shipped-loop behaviour.
  # What it covers: `[ … -ge 10 ]` parses base 10 but `$(( … ))` parses base 0, where `010` is octal
  # 8 — so the guard ratifies "ten" and an un-normalised arithmetic would return 9, landing in OWN,
  # the same unsafe direction the tunable-keyed fallback was fixed for. The `10#` keeps it at 11.
  _mp="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" MERGE_PRIORITY_AT=010 bash "$OC/drive.sh" )"
  [ "$_mp" = "11" ] && rc=0 || { rc=1; echo "      MERGE_PRIORITY_AT=010 produced '$_mp' (expected 11)"; }
  ck "unit (guard bypassed): a raw leading-zero tunable 010 normalises to base 10 (11), not octal 8 (9)" $rc
  _mp="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" MERGE_PRIORITY_AT=notanum bash "$OC/drive.sh" )"
  [ "$_mp" = "26" ] && rc=0 || { rc=1; echo "      MERGE_PRIORITY_AT=notanum produced '$_mp' (expected 26)"; }
  ck "a non-numeric MERGE_PRIORITY_AT falls back to 26 without aborting" $rc
  # (c) SUCCESS: the count is returned and persisted for the next failure
  cat > "$OC/gh" <<'SH'
#!/bin/bash
printf '25\n'
SH
  chmod +x "$OC/gh"; rm -f "$OC/state/last-open-n"; : > "$LOG"
  n="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" bash "$OC/drive.sh" )"
  [ "$n" = "25" ] && rc=0 || { rc=1; echo "      success produced '$n'"; }
  ck "a successful open-PR count returns the count" $rc
  [ "$(cat "$OC/state/last-open-n" 2>/dev/null)" = "25" ] && rc=0 || rc=1
  ck "a successful open-PR count is persisted to last-open-n" $rc
  # (c2) a GENUINE 0 (drained queue) must still be returned as 0 and persisted: the `-gt 0` guard
  # lives ONLY in the failure branch. Coercing a real 0 to 26 would make BROAD permanent and the
  # queue would never be treated as drained.
  cat > "$OC/gh" <<'SH'
#!/bin/bash
printf '0\n'
SH
  chmod +x "$OC/gh"; rm -f "$OC/state/last-open-n"; : > "$LOG"
  n="$( PATH="$OC:$PATH" O="$OC" OR="acme/widget" LOG="$LOG" bash "$OC/drive.sh" )"
  [ "$n" = "0" ] && rc=0 || { rc=1; echo "      success-0 produced '$n'"; }
  ck "a genuine 0 (drained queue) is still returned as 0" $rc
  [ "$(cat "$OC/state/last-open-n" 2>/dev/null)" = "0" ] && rc=0 || rc=1
  ck "a genuine 0 is persisted to last-open-n" $rc
fi
# The SEAM, not just the logic: a perfect open_pr_count() is dead code if the loop stops calling it.
# Review mutation (G) restored the pre-fix inline line at the call site — `OPEN_N="$(gh pr list …)";
# : "${OPEN_N:=0}"` — and left the extracted-function checks green because nothing pinned the wiring.
grep -qF 'OPEN_N="$(open_pr_count)"' "$LOOP" && rc=0 || { rc=1; echo "      the loop does not assign OPEN_N from open_pr_count()"; }
ck "the loop actually calls open_pr_count() (not the pre-fix inline gh count)" $rc
# The sweep listing must be captured and rc-checked too: piped straight into `while read` with
# 2>/dev/null, a failed listing is ZERO iterations and no output — a sweep that silently does
# nothing for the whole cycle. These pin the fix's shape; (a) above pins its behavioural sibling.
grep -q 'SWEEP_RC' "$LOOP" && rc=0 || rc=1
ck "the sweep listing captures its rc instead of discarding it" $rc
grep -q 'PR listing FAILED' "$LOOP" && rc=0 || rc=1
ck "a failed sweep listing is logged, not silently empty" $rc
# …and the sweep loop must be fed the CAPTURED listing: a shape that logs the failure but still
# pipes gh directly would sweep an empty list around the captured variable.
grep -qF '${SWEEP_LIST:-}" |' "$LOOP" && rc=0 || rc=1
ck "the sweep loop is fed the captured listing, not gh directly" $rc

# ── 16b) the SCOPE override pins the drain scope, and a bad value fails loudly ───
# Extracted VERBATIM from the shipped orch-loop.sh (the BEGIN/END scope-select markers), driven in
# a subshell with SCOPE/OPEN_N/LOG set. A check that re-implemented the case statement would pass
# on a build with no override at all — the exact vacuity this file exists to prevent.
awk '/^  # BEGIN scope-select/,/^  # END scope-select/' "$LOOP" > "$TMP/scope.sh"
if need "$TMP/scope.sh" "the scope-select block is extracted from the shipped orch-loop.sh"; then
  S_OWN='select(.headRefName|test("-tm$|-cap$|^fix/"))'
  S_BROAD='select(.headRefName|test("^design/|^scope/|^dependabot/")|not)'
  drive_scope() { # <SCOPE> <OPEN_N> -> "<MODE>|<SEL>"; log $TMP/scope.log; err $TMP/scope.err
    : > "$TMP/scope.log"; : > "$TMP/scope.err"
    ( set -u; SCOPE="$1" OPEN_N="$2" LOG="$TMP/scope.log"; . "$TMP/scope.sh"; printf '%s|%s\n' "$SCOPE_MODE" "$SEL" ) 2>"$TMP/scope.err"
  }
  # auto (the default) must preserve the pre-override count rule exactly.
  out="$(drive_scope auto 14)"
  [ "$out" = "BROAD|$S_BROAD" ] && grepp=true || grepp=false
  grep -qF '[scope] open=14 -> BROAD (auto)' "$TMP/scope.log" && grepl=true || grepl=false
  [ "$grepp" = true ] && [ "$grepl" = true ] && rc=0 || { rc=1; echo "      auto/14 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: auto + 14 open -> BROAD, unchanged" $rc
  # SCOPE UNSET (the real default path — every test above sets SCOPE explicitly) must drive `auto`.
  # Without this, a mutation of the default itself (e.g. ${SCOPE+x} -> ${SCOPE:-own}) stays green.
  drive_scope_unset() { # <OPEN_N> -> "<MODE>|<SEL>" with SCOPE genuinely unset
    : > "$TMP/scope.log"; : > "$TMP/scope.err"
    ( set -u; unset SCOPE; OPEN_N="$1" LOG="$TMP/scope.log"; . "$TMP/scope.sh"; printf '%s|%s\n' "$SCOPE_MODE" "$SEL" ) 2>"$TMP/scope.err"
  }
  out="$(drive_scope_unset 14)"
  grep -qF '[scope] open=14 -> BROAD (auto)' "$TMP/scope.log" && grepl=true || grepl=false
  [ "$out" = "BROAD|$S_BROAD" ] && [ "$grepl" = true ] && rc=0 || { rc=1; echo "      unset/14 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: SCOPE unset drives the auto default (>10 -> BROAD)" $rc
  out="$(drive_scope_unset 10)"
  # The log line is asserted too: at OPEN_N=10 `auto` and a mutated `own` DEFAULT are
  # indistinguishable from MODE alone, so an unset-default mutation would stay green here.
  grep -qF '[scope] open=10 -> OWN (auto)' "$TMP/scope.log" && grepl=true || grepl=false
  [ "$out" = "OWN|$S_OWN" ] && [ "$grepl" = true ] && rc=0 || { rc=1; echo "      unset/10 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: SCOPE unset drives the auto default (at the threshold -> OWN)" $rc
  out="$(drive_scope auto 10)"
  [ "$out" = "OWN|$S_OWN" ] && grepp=true || grepp=false
  grep -qF '[scope] open=10 -> OWN (auto)' "$TMP/scope.log" && grepl=true || grepl=false
  [ "$grepp" = true ] && [ "$grepl" = true ] && rc=0 || { rc=1; echo "      auto/10 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: auto + 10 open (at the threshold) -> OWN, unchanged" $rc
  # own/broad must pin, in BOTH directions across the threshold.
  out="$(drive_scope own 14)"
  [ "$out" = "OWN|$S_OWN" ] && grep -qF '[scope] open=14 -> OWN (pinned SCOPE=own)' "$TMP/scope.log" && rc=0 \
    || { rc=1; echo "      own/14 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: SCOPE=own pins OWN even above the threshold" $rc
  out="$(drive_scope broad 3)"
  [ "$out" = "BROAD|$S_BROAD" ] && grep -qF '[scope] open=3 -> BROAD (pinned SCOPE=broad)' "$TMP/scope.log" && rc=0 \
    || { rc=1; echo "      broad/3 got '$out' log=$(cat "$TMP/scope.log")"; }
  ck "shipped scope: SCOPE=broad pins BROAD even below the threshold" $rc
  # A typo is FATAL operator config — it must not silently pick a scope.
  drive_scope banana 14 >/dev/null; rc=$?
  [ "$rc" -ne 0 ] && rc=0 || { rc=1; echo "      SCOPE=banana exited 0"; }
  ck "shipped scope: an unknown SCOPE value fails (does not pick a scope)" $rc
  grep -qF 'SCOPE must be auto|own|broad' "$TMP/scope.err" && rc=0 || { rc=1; echo "      stderr: $(cat "$TMP/scope.err")"; }
  ck "shipped scope: the unknown-value failure names the accepted values" $rc
  # Set-but-EMPTY is an operator typo (a blank plist/keys.env entry), not a silent default.
  drive_scope '' 14 >/dev/null; rc=$?
  [ "$rc" -ne 0 ] && rc=0 || { rc=1; echo "      SCOPE= (empty) exited 0 — silently picked a scope"; }
  ck "shipped scope: SCOPE set-but-empty fails instead of defaulting" $rc
  # The SEAM: the sweep must CONSUME the block's $SEL. A build where the jq hardcodes a filter
  # still logs the scope correctly but never changes what is swept — the override is inert.
  grep -qF '|$SEL|' "$LOOP" && rc=0 || { rc=1; echo "      the sweep jq does not interpolate \$SEL"; }
  ck "shipped scope: the sweep actually consumes \$SEL" $rc
  unset -f drive_scope drive_scope_unset
fi

# ── 16c) the launchers can actually SET the scope (else the pin is unreachable) ───
# launchd inherits NO shell env, so a SCOPE that install.sh does not render into the plist cannot
# be pinned on a second Mac — the pin would be documentation only. The template must carry it,
# install.sh must render it, and install.sh must refuse a bad value at install time.
grep -qF '__SCOPE__' "$HERE/launchd.plist.template" && rc=0 || rc=1
ck "the plist template carries a SCOPE key" $rc
grep -qF '__SCOPE__' "$INST" && rc=0 || rc=1
ck "the SCOPE placeholder is present in install.sh (diagnostic; the value is asserted below)" $rc
# Sandboxed, and the refusal REASON is asserted: without HOME/REPO/O overrides, a mutant that
# deletes the validator still exits non-zero (an unrelated preflight failure), so an rc-only check
# would stay green — and on a host where the default REPO exists it would write a plist into the
# operator's REAL ~/Library/LaunchAgents.
( SCOPE=banana HOME="$SB" O="$TMP/sb-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >/dev/null 2>"$TMP/inst.err" ); rc=$?
[ "$rc" -ne 0 ] && rc=0 || { rc=1; echo "      install.sh accepted SCOPE=banana (rc=$rc)"; }
ck "install.sh refuses an invalid SCOPE" $rc
grep -qF 'SCOPE must be auto|own|broad' "$TMP/inst.err" && rc=0 || { rc=1; echo "      stderr: $(cat "$TMP/inst.err")"; }
ck "install.sh refuses it for the SCOPE reason, naming the accepted values" $rc

# The rendered VALUE, not just the placeholder. A render that ignores $SCOPE entirely (e.g. a
# hardcoded `s|__SCOPE__|auto|g`) leaves the literal '__SCOPE__' in install.sh's own source, so
# both greps above stay green while the pin silently evaporates at install time. Assert the value
# that actually lands in the plist, through the real installer.
if on_darwin; then
PL2="$SB/Library/LaunchAgents/$TPL"
render_scope() {   # $1 = a value, or the literal __UNSET__
  if [ "$1" = "__UNSET__" ]; then
    HOME="$SB" O="$TMP/sb-o" REPO="$HERE/../.." OR="acme/widget" env -u SCOPE bash "$INST" >/dev/null 2>&1
  else
    HOME="$SB" O="$TMP/sb-o" REPO="$HERE/../.." OR="acme/widget" SCOPE="$1" bash "$INST" >/dev/null 2>&1
  fi
  plutil -extract EnvironmentVariables.SCOPE raw "$PL2" 2>/dev/null || echo MISSING
}
for want in own broad; do
  got="$(render_scope "$want")"
  [ "$got" = "$want" ] && rc=0 || { rc=1; echo "      rendered SCOPE='$got', wanted '$want'"; }
  ck "the plist renders SCOPE=$want, not a hardcoded default" $rc
done
got="$(render_scope __UNSET__)"
[ "$got" = "auto" ] && rc=0 || { rc=1; echo "      rendered SCOPE='$got', wanted 'auto'"; }
ck "an UNSET SCOPE renders the auto default" $rc
else
  skipd "install.sh's plist SCOPE render checks (§16b) — install.sh is macOS-only (launchd); skipped on $PLATFORM"
fi

# set-but-EMPTY is FATAL on BOTH launchers — a blank plist / keys.env entry must not become `auto`,
# which is the shared-queue drain the override exists to prevent. install.sh:
( SCOPE= HOME="$SB" O="$TMP/sb-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >/dev/null 2>"$TMP/inst.empty.err" ); rc=$?
[ "$rc" -ne 0 ] && rc=0 || { rc=1; echo "      install.sh accepted a set-but-empty SCOPE"; }
ck "install.sh refuses a set-but-empty SCOPE (never coerced to auto)" $rc
# ... and the cell supervisor, which forwards it into the tmux session's command string. Provision
# CELL_HOME and the repo so a non-zero rc cannot come from cmd_check's preflight, require the SCOPE
# message so a neutered validator cannot pass on a preflight rc, and put the tmux stub FIRST on
# PATH — under the very regression this check guards (a validator that passes), the supervisor would
# otherwise create a REAL session and execute the live controller.
# A fixture harness that is a REAL checkout at a REAL ref. Since #1745 cmd_check runs
# cmd_check_provenance, which asks WHICH COMMIT the harness is: a harness that is a bare copy of
# $HERE (untracked), or HEAD of a PR merge commit (diverged), is refused `DRIFT (...)`, and the
# SCOPE/key verdicts below are then never reached. Build a throwaway repo whose origin/main IS its
# HEAD and point every supervisor invocation in 16d-16f at $HFIX_H. HARNESS_FETCH=0 keeps the
# suite offline (the supervisor default is 1).
HFIX="$TMP/hfix"; HFIX_H="$HFIX/scripts/orchestrator-harness"
git init -q "$HFIX"
git -C "$HFIX" config user.email selftest@test.local
git -C "$HFIX" config user.name selftest
git -C "$HFIX" config commit.gpgsign false
mkdir -p "$HFIX_H"; cp "$HERE"/*.sh "$HFIX_H/"
git -C "$HFIX" add -A; git -C "$HFIX" commit -q -m "selftest fixture harness"
git -C "$HFIX" branch -M main
git -C "$HFIX" update-ref refs/remotes/origin/main "$(git -C "$HFIX" rev-parse HEAD)"

git init -q "$TMP/cellrepo"
# #1717: cmd_check now refuses a cell with no record-review.sh, so every fixture that reaches the
# dependency probe needs one. These cases die at validate_scope() first, so the stub is for the
# shapes that do not.
mkdir -p "$TMP/cellhome/.pi/agent/scripts"
printf '#!/bin/bash\nexit 0\n' > "$TMP/cellhome/.pi/agent/scripts/record-review.sh"
chmod +x "$TMP/cellhome/.pi/agent/scripts/record-review.sh"
# #1717: the recorder's declared sibling, so a fixture that reaches cmd_check is not refused on it.
mkdir -p "$TMP/cellhome/.pi/agent/scripts/lib"
printf '#!/usr/bin/env python3\n' > "$TMP/cellhome/.pi/agent/scripts/lib/diff-normalize.py"
STUB_TM="$TMP/stub-tm"; mkdir -p "$STUB_TM"
# #1717: cmd_check now probes git/python3/pi as runtime dependencies. On the ubuntu CI runner `pi` is
# not installed (install.sh's own pi gate is skipped there by this suite's platform gate), so a
# fixture that reaches the probe must stub it instead of leaning on the host PATH — otherwise the
# suite reddens on the runner only (the #1348/#1369 lane-split class).
# ⛔ Stub the GAPS ONLY — stubbing a tool the fixture itself needs SHADOWS the real one, and the
# provenance gate then reads the stub: `git -C "$HARNESS_REPO" rev-parse` returns EMPTY, the harness
# classifies as `unknown`, and cmd_check refuses with "Cannot-verify is never a pass" — so every
# case below would assert against a DRIFT refusal instead of the verdict under test.
for c in pi git python3; do command -v "$c" >/dev/null 2>&1 || { printf '#!/bin/bash\nexit 0\n' > "$STUB_TM/$c"; chmod +x "$STUB_TM/$c"; }; done
cat > "$STUB_TM/tmux" <<'STUB'
#!/bin/bash
case "$1" in
  has-session) [ -f "$TM_STATE/up" ] && exit 0 || exit 1 ;;
  new-session) shift; printf '%s\n' "$*" > "$TM_STATE/cmd"; : > "$TM_STATE/up"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$STUB_TM/tmux"
# The stub must be ABLE to record a session: without this the new-session write fails, so the
# session-file clause below could never fire and a mutant that started a real session would surface
# only through the refusal-message clause. Created empty, the stub still reports has-session=absent.
mkdir -p "$TMP/sup-empty"
( SCOPE= PATH="$STUB_TM:$PATH" TM_STATE="$TMP/sup-empty" HOME="$TMP/cellhome" CELL_HOME="$TMP/cellhome" REPO="$TMP/cellrepo" O="$TMP/sb-o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>"$TMP/sup.empty.err" ); rc=$?
# ONE conjunction. This was two statements and the second RECOMPUTED rc from its own exit status,
# discarding the first — so a mutant that created the session and only then died with the SCOPE
# message printed the violation and still reported PASS. Each clause must hold for the PASS: a
# non-zero rc, NO session file (the stub above can now truly record one), and the refusal message.
[ "$rc" -ne 0 ] && [ ! -f "$TMP/sup-empty/cmd" ] && grep -qF 'SCOPE must be auto|own|broad' "$TMP/sup.empty.err" && rc=0 \
  || { rc=1; echo "      a session was created, or the SCOPE refusal was not reached; stderr: $(tail -2 "$TMP/sup.empty.err")"; }
ck "the cell supervisor refuses a set-but-empty SCOPE, naming the accepted values" $rc

# ... and `check` must refuse it too. Its verdict is the literal line `CELL CAN RUN A CONTROLLER`, so a
# preflight that certifies a SCOPE its own `start` then dies on is a FALSE PASS on the only question
# that verdict answers. Driven with a value NEITHER subcommand accepts, and both halves asserted: the
# refusal names the accepted values, AND the certification line is absent.
( SCOPE=banana PATH="$STUB_TM:$PATH" TM_STATE="$TMP/sup-chkbad" HOME="$TMP/cellhome" CELL_HOME="$TMP/cellhome" REPO="$TMP/cellrepo" O="$TMP/sb-o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 \
    bash "$HERE/../cloud-cell-supervisor.sh" check >"$TMP/sup.chkbad.out" 2>"$TMP/sup.chkbad.err" ); rc=$?
[ "$rc" -ne 0 ] && grep -qF 'SCOPE must be auto|own|broad' "$TMP/sup.chkbad.err" \
  && ! grep -qF 'CELL CAN RUN A CONTROLLER' "$TMP/sup.chkbad.out" && rc=0 \
  || { rc=1; echo "      check certified (or failed to refuse) SCOPE=banana; stderr: $(tail -2 "$TMP/sup.chkbad.err")"; }
ck "the cell supervisor's check refuses a bad SCOPE instead of certifying the cell" $rc

# install.sh must refuse the SAME $O its controller refuses: a plist that renders here but is
# rejected there is worse than a refusal — RunAtLoad+KeepAlive relaunches a guaranteed-fatal
# controller forever. BOTH guards are driven over the same eight values — orch-loop.sh's extracted
# here, install.sh's END TO END below — so the two cannot drift apart silently.
# Drive the SHIPPED guard, EXTRACTED — never the live controller: running orch-loop.sh to test it
# would enter its dispatch loop with the DEFAULT OR (daniel-ospina/tortoise) and could merge PRs if
# the guard regressed — the very regression this check exists to catch (the suite must stay
# offline: "No network, no tmux server, no git writes").
awk '/^case "\$O" in/{f=1} f{print} f&&/^esac/{exit}' "$HERE/orch-loop.sh" > "$TMP/oguard.sh"
if need "$TMP/oguard.sh" "the \$O guard is extracted from the shipped orch-loop.sh"; then
  # Every member of the class, not just a space: the guard has eight alternatives and the SPACE is
  # inert — the quote and the metacharacters are the ones that enable the sh -c break-out, so a
  # mutated guard that lost them must not stay green.
  for bad in 'o space' "o'q" 'o"q' 'o`q' 'o$q' 'o;q' 'o|q' 'o&q'; do
    ( O="$TMP/$bad"; . "$TMP/oguard.sh" ) >/dev/null 2>&1; rc=$?
    ck "orch-loop.sh's \$O guard refuses '$bad'" $([ "$rc" -ne 0 ] && echo 0 || echo 1)
  done
  ( O="$TMP/clean-o"; . "$TMP/oguard.sh" ) >/dev/null 2>&1; rc=$?
  ck "orch-loop.sh's \$O guard accepts a clean path (non-vacuity)" $([ "$rc" -eq 0 ] && echo 0 || echo 1)
fi
# install.sh's guard is driven END TO END over the SAME eight values. Driving it for only the space
# (and the quote) left seven alternatives unpinned: narrowing install.sh's list to quote+space alone
# kept the whole suite green, while install.sh would render a plist for an $O the controller refuses
# forever — the exact failure the pair of checks exists to prevent.
SB5="$TMP/sb5"; mkdir -p "$SB5/Library/LaunchAgents" "$SB5/.config" "$SB5/.pi/agent/scripts"
ln -s "$HOME/.config/gh" "$SB5/.config/gh" 2>/dev/null || true
mkdir -p "$SB5/.local/share/pi-node/current/bin"
printf '#!/bin/bash\nexit 0\n' > "$SB5/.local/share/pi-node/current/bin/pi"; chmod +x "$SB5/.local/share/pi-node/current/bin/pi"
if on_darwin; then
( HOME="$SB5" O="$TMP/clean-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >/dev/null 2>"$TMP/inst.clean.err" ); rc=$?
[ "$rc" -eq 0 ] && rc=0 || { rc=1; echo "      install.sh refused a clean \$O: $(tail -2 "$TMP/inst.clean.err")"; }
ck "install.sh accepts a clean \$O (non-vacuity for the guard loop below)" $rc
else
  skipd "install.sh accepts a clean \$O (§16d) — install.sh is macOS-only (launchd); skipped on $PLATFORM"
fi
for bad in 'o space' "o'q" 'o"q' 'o`q' 'o$q' 'o;q' 'o|q' 'o&q'; do
  ( HOME="$SB5" O="$TMP/$bad" REPO="$HERE/../.." OR="acme/widget" bash "$INST" >/dev/null 2>"$TMP/inst.og.err" ); rc=$?
  [ "$rc" -ne 0 ] && grep -qF 'metacharacter' "$TMP/inst.og.err" && rc=0 \
    || { rc=1; echo "      install.sh accepted \$O='$bad': $(tail -2 "$TMP/inst.og.err")"; }
  ck "install.sh refuses the same \$O orch-loop.sh refuses: '$bad'" $rc
done

# --uninstall renders nothing, so an unrelated SCOPE typo must not block it: the operator removing
# a misbehaving daemon is exactly who must not be stopped by it. ELDATO_ALLOW_TEST_HOME=1 is the #446
# opt-in — this $HOME is a sandbox, so install.sh would otherwise (correctly) refuse to touch launchd;
# with it, the `launchctl` stub above stands in for the real domain.
( HOME="$SB" ELDATO_ALLOW_TEST_HOME=1 SCOPE=banana bash "$INST" --uninstall >/dev/null 2>&1 ); rc=$?
[ "$rc" -eq 0 ] && rc=0 || { rc=1; echo "      install.sh --uninstall was blocked by SCOPE=banana"; }
ck "install.sh --uninstall is not blocked by an invalid SCOPE" $rc

# A ZERO-BYTE key file is not a key: `-f` blessed it, and the daemon then recorded reviews
# UNSIGNED and failed ai-review-gate — the env-only failure with the file branch taken (README §7.4).
if on_darwin; then
: > "$SB/.pi/agent/.ai-review-gate-key"
ikout="$(HOME="$SB" O="$TMP/ik-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" 2>&1)"
case "$ikout" in *'gate key file present'*) rc=1; echo "      install.sh blessed an empty key file" ;; *) rc=0 ;; esac
ck "install.sh does not bless a ZERO-BYTE key file" $rc
printf 'k\n' > "$SB/.pi/agent/.ai-review-gate-key"
ikout="$(HOME="$SB" O="$TMP/ik-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" 2>&1)"
rm -f "$SB/.pi/agent/.ai-review-gate-key"
case "$ikout" in *'gate key file present'*) rc=0 ;; *) rc=1; echo "      install.sh did not report a non-empty key file" ;; esac
ck "install.sh reports a NON-EMPTY key file present (non-vacuity)" $rc
# The consumer strips whitespace, so a 1-byte newline (what `echo "$KEY" > file` writes for an unset
# variable) is NOT a key — size alone must not bless it.
printf '\n' > "$SB/.pi/agent/.ai-review-gate-key"
ikout="$(HOME="$SB" O="$TMP/ik-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" 2>&1)"
rm -f "$SB/.pi/agent/.ai-review-gate-key"
case "$ikout" in *'gate key file present'*) rc=1; echo "      install.sh blessed a whitespace-only key file" ;; *) rc=0 ;; esac
ck "install.sh does not bless a WHITESPACE-ONLY key file" $rc
# An EXISTING but UNREADABLE key file is neither missing nor empty. The verdict must name it, or the
# prescribed remedy ("write the key with printf") is given for a file that may already hold one.
printf 'secret\n' > "$SB/.pi/agent/.ai-review-gate-key"; chmod 000 "$SB/.pi/agent/.ai-review-gate-key"
ikout="$(HOME="$SB" O="$TMP/ik-o" REPO="$HERE/../.." OR="acme/widget" bash "$INST" 2>&1)"
chmod 600 "$SB/.pi/agent/.ai-review-gate-key"
rm -f "$SB/.pi/agent/.ai-review-gate-key"
case "$ikout" in *'NOT READABLE'*) rc=0 ;; *) rc=1; echo "      install.sh did not name an unreadable key file: $(printf '%s\n' "$ikout" | grep -i 'key' | head -2)";; esac
ck "install.sh names an EXISTING-BUT-UNREADABLE key file as such, not as empty" $rc
else
  skipd "install.sh's gate-key file verdict (§16d) — install.sh is macOS-only (launchd); skipped on $PLATFORM"
fi

# ── 16e) the cell supervisor FORWARDS the SCOPE it validated ─────────────────
# A tmux server supplies a new session's environment, so an exported SCOPE is silently dropped and
# the cell falls back to `auto` — a pin that is not INLINED into the session's command string is
# documentation, not a setting. Drive the shipped cmd_start with a tmux stub that records the
# command it is handed (this is the only place the forwarding can be observed).
TM="$TMP/tm/bin"; mkdir -p "$TM" "$TMP/tm/home" "$TMP/tm/harness"
# A REAL checkout, not a mocked `.git` directory (see the §16fixture below): since #1745 cmd_check
# verifies the repo with `git -C "$REPO" rev-parse --git-dir`, so an empty `.git` dir is refused
# before any session command can be recorded.
git init -q "$TMP/tm/repo"
# ⛔ agent-infra#1901: the queue's repo is DERIVED from $REPO's `origin` remote, and a pair that
# cannot be READ is refused (cannot-verify is never a pass) — so a fixture checkout must carry one,
# or every case below is decided by the queue refusal instead of the forwarding/injection guard it
# names. `acme/widget` matches the OR the injection arms already pass.
git -C "$TMP/tm/repo" remote add origin https://github.com/acme/widget.git
cp "$HERE"/*.sh "$TMP/tm/harness/"
# The supervisor's `check` now also judges DISPATCH PROVISIONING (agent-infra#1736), so the fixture
# must model a repo that can be pre-flighted: a repo carrying its own tools/collision_preflight.py.
# Without it `start` dies in cmd_check and no session command is ever recorded.
mkdir -p "$TMP/tm/repo/tools"; : > "$TMP/tm/repo/tools/collision_preflight.py"
# #1717: the recorder must be deliverable two ways — pre-existing in the cell's HOME, and (the
# provision path) as the canonical copy one directory up from the harness. Both are placed so no
# check below depends on the order the others ran in; the provision path itself is covered by
# cloud-cell-record-dep.test.sh.
mkdir -p "$TMP/tm/home/.pi/agent/scripts"
printf '#!/bin/bash\nexit 0\n' > "$TMP/tm/home/.pi/agent/scripts/record-review.sh"
chmod +x "$TMP/tm/home/.pi/agent/scripts/record-review.sh"
printf '#!/bin/bash\nexit 0\n' > "$TMP/tm/record-review.sh"
chmod +x "$TMP/tm/record-review.sh"
# #1717: cmd_check refuses a cell whose recorder lacks its declared sibling lib/diff-normalize.py.
mkdir -p "$TMP/tm/home/.pi/agent/scripts/lib"
printf '#!/usr/bin/env python3\n' > "$TMP/tm/home/.pi/agent/scripts/lib/diff-normalize.py"
# …and the runtime-dependency probe needs `pi` (absent on the ubuntu CI runner). Stub the GAPS ONLY,
# for the reason spelled out at $STUB_TM above: a `git` stub empties the provenance gate's rev-parse
# and turns a current harness into an unverifiable one.
for c in pi git python3; do command -v "$c" >/dev/null 2>&1 || { printf '#!/bin/bash\nexit 0\n' > "$TM/$c"; chmod +x "$TM/$c"; }; done
# NAME-AWARE since #1989: `start` now creates TWO sessions (the controller, then the cell doctor),
# and a stub whose `has-session` answers "up" for ANY name makes the second one short-circuit as
# "already running" — so the doctor's own command string (which must carry the operator's SCOPE and
# ENV_FILE, because it can restart the controller) would never be recorded or asserted.
cat > "$TM/tmux" <<'STUB'
#!/bin/bash
sub="${1:-}"; shift
args="$*"
n=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-s" ] || [ "$1" = "-t" ]; then n="$2"; shift 2; else shift; fi
done
case "$sub" in
  has-session)
    [ -n "$n" ] && grep -qxF -- "${n#=}" "$TM_STATE/names" 2>/dev/null && exit 0
    exit 1 ;;
  new-session)
    [ -n "$n" ] && printf '%s\n' "$n" >> "$TM_STATE/names"
    printf '%s\n' "$args" >> "$TM_STATE/cmd"
    : > "$TM_STATE/up"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
printf '#!/bin/bash\nexit 0\n' > "$TM/gh"
chmod +x "$TM/tmux" "$TM/gh"
sup_start() {  # $1 = the SCOPE value to start with (__UNSET__ omits it)
  rm -f "$TMP/tm/up" "$TMP/tm/cmd" "$TMP/tm/names"
  if [ "$1" = "__UNSET__" ]; then
    env -u SCOPE PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
      REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 \
      bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>&1
  else
    PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
      REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 SCOPE="$1" \
      bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>&1
  fi
}
for want in own broad __UNSET__; do
  sup_start "$want"
  wantval="$want"; [ "$want" = "__UNSET__" ] && wantval=auto
  grep -qF "SCOPE='$wantval'" "$TMP/tm/cmd" 2>/dev/null && rc=0 || { rc=1; echo "      forwarded: $(cat "$TMP/tm/cmd" 2>/dev/null)"; }
  ck "the cell supervisor inlines SCOPE=$wantval for '$want' into the session command" $rc
done
# ⛔ THE DOCTOR SESSION RESTARTS THE CONTROLLER, so its command string must carry the operator's
# configuration too (#1989 review round 2): a loop that re-derived SCOPE from the default would bring
# a pin-OWN cell back as AUTO (= BROAD above 10 open PRs, draining the shared queue), and a custom
# ENV_FILE lost would silently drop the merge key. Asserted on the SECOND recorded new-session line.
sup_start own
docline="$(grep 'cloud-cell-doctor\.sh' "$TMP/tm/cmd" 2>/dev/null | tail -1)"
case "$docline" in
  *"SCOPE='own'"*) rc=0 ;;
  *) rc=1; echo "      doctor session: ${docline:-<no doctor session recorded>}" ;;
esac
ck "the doctor loop's session command carries SCOPE (a restart must not re-derive it)" $rc
case "$docline" in
  *"ENV_FILE='"*) rc=0 ;;
  *) rc=1; echo "      doctor session: ${docline:-<none>}" ;;
esac
ck "the doctor loop's session command carries ENV_FILE" $rc

# UNSET must reach the controller as the auto default being absent-or-auto — but a typo/blank must
# die BEFORE a session is created (nothing started, no tmux command recorded).
rm -f "$TMP/tm/up" "$TMP/tm/cmd" "$TMP/tm/names"
( SCOPE= PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$TMP/tm/cmd" ] && rc=0 || { rc=1; echo "      rc=$rc; cmd recorded: $([ -f "$TMP/tm/cmd" ] && echo yes || echo no)"; }
ck "a set-but-empty SCOPE is refused BEFORE any session is started" $rc

# Every interpolated value must be metacharacter-free (the session string is handed to tmux, which
# runs it with sh -c), so a quote in $O must be refused BEFORE a session exists — and before any
# injected command could run. The sibling guards in orch-loop.sh and install.sh are asserted above.
# The payload is a quote with NO literal space (${IFS} stands in for it): a guard that kept only the
# space alternative would accept this, so the check pins the quote member — the one that actually
# enables the break-out — not merely the class as a whole.
rm -f "$TMP/tm/up" "$TMP/tm/cmd" "$TMP/tm/names" "$TMP/tm/names" "$TMP/tm/INJECTED"
( PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/it';touch\${IFS}$TMP/tm/INJECTED;#" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>"$TMP/sup.meta.err" ); rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$TMP/tm/cmd" ] && [ ! -f "$TMP/tm/INJECTED" ] && rc=0 \
  || { rc=1; echo "      rc=$rc; session recorded: $([ -f "$TMP/tm/cmd" ] && echo yes || echo no); injected: $([ -f "$TMP/tm/INJECTED" ] && echo yes || echo no)"; }
ck "a metacharacter in \$O is refused before any session is created" $rc

# The session string carries OR too, and the guard must cover it — this is the value whose omission
# was a live injection (a quote in OR broke out of the sh -c string and executed a command).
rm -f "$TMP/tm/up" "$TMP/tm/cmd" "$TMP/tm/names"
( PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 SCOPE=own OR="acme/x';touch\${IFS}$TMP/tm/ORPWN;#" \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>"$TMP/sup.or.err" ); rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$TMP/tm/cmd" ] && [ ! -f "$TMP/tm/ORPWN" ] && rc=0 \
  || { rc=1; echo "      rc=$rc; session recorded: $([ -f "$TMP/tm/cmd" ] && echo yes || echo no)"; }
ck "a metacharacter in \$OR is refused before any session is created" $rc
# The QUOTE is the break-out enabler, so drive it ALONE — no $, ; or # for another alternative to
# match: a guard that lost only the quote alternatives must still go red here.
rm -f "$TMP/tm/up" "$TMP/tm/cmd" "$TMP/tm/names"
( PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/it'q" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$TMP/tm/cmd" ] && rc=0 \
  || { rc=1; echo "      rc=$rc; session recorded: $([ -f "$TMP/tm/cmd" ] && echo yes || echo no)"; }
ck "a QUOTE-ONLY \$O is refused (the quote is the break-out enabler)" $rc
rm -f "$TMP/tm/up" "$TMP/tm/cmd" "$TMP/tm/names"
( PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 SCOPE=own OR="acme/x'q" \
    bash "$HERE/../cloud-cell-supervisor.sh" start >/dev/null 2>&1 ); rc=$?
[ "$rc" -ne 0 ] && [ ! -f "$TMP/tm/cmd" ] && rc=0 \
  || { rc=1; echo "      rc=$rc; session recorded: $([ -f "$TMP/tm/cmd" ] && echo yes || echo no)"; }
ck "a QUOTE-ONLY \$OR is refused (the quote is the break-out enabler)" $rc
# The merge key must NOT be interpolated into the session string at all: a secret in an argv string
# is visible to ps/tmux, and it was the other unguarded member of this same class. It reaches the
# session through \$ENV_FILE (which the session re-sources).
sup_start own
if [ -s "$TMP/tm/cmd" ]; then
  grep -qF 'AI_REVIEW_GATE_KEY' "$TMP/tm/cmd" && rc=1 || rc=0
else
  rc=1; echo "      no session command was recorded to inspect"
fi
ck "the session command string does not carry the merge key" $rc
# The same EXISTING-BUT-UNREADABLE distinction in the preflight: a cell whose key file is mode 000
# must be told so — "no key" is a different fault with a different remedy. Drive `check` itself
# (the verdict a cell trusts), with the ambient key unset so the branch under test is reached.
mkdir -p "$TMP/tm/home/.pi/agent"
printf 'secret\n' > "$TMP/tm/home/.pi/agent/.ai-review-gate-key"
chmod 000 "$TMP/tm/home/.pi/agent/.ai-review-gate-key"
supchk="$( env -u AI_REVIEW_GATE_KEY PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$TMP/tm/home" CELL_HOME="$TMP/tm/home" \
    REPO="$TMP/tm/repo" O="$TMP/tm/o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" check 2>&1 )"
chmod 600 "$TMP/tm/home/.pi/agent/.ai-review-gate-key"
rm -f "$TMP/tm/home/.pi/agent/.ai-review-gate-key"
case "$supchk" in *'NOT READABLE'*) rc=0 ;; *) rc=1; echo "      the preflight did not name the unreadable key: $(printf '%s\n' "$supchk" | grep -i 'key' | head -2)";; esac
ck "the cell preflight names an EXISTING-BUT-UNREADABLE key file as such" $rc

# ── 16f) cmd_check judges the merge key by what the SESSION will receive ────────
# The session re-sources $ENV_FILE, so a key in that file reaches the controller while an
# ambient-only export does NOT (tmux serves a new session the server's environment). Reporting the
# ambient one as "present" was a false green on a cell that merges without the key.
KC="$TMP/kc"; mkdir -p "$KC/home" "$KC/o" "$KC/harness"
# ⛔ A REAL checkout, not a mocked `.git` directory. `mkdir -p "$KC/repo/.git"` passed the old
# `[ -d "$REPO/.git" ]` test, but since #1745 cmd_check asks the real question —
# `git -C "$REPO" rev-parse --git-dir` — because a LINKED worktree has a `.git` FILE, and the old
# `-d`-only test false-blocked it. An empty `.git` directory is not a git checkout, so the fixture
# must be one or every case below dies at the repo gate before reaching the key verdicts.
git init -q "$KC/repo"
# ⛔ agent-infra#1901: `cmd_check` derives the queue's repo from $REPO's `origin` remote and refuses a
# pair it cannot READ, so the fixture checkout needs one — otherwise every key verdict below is
# decided by the queue refusal rather than by the key probe it names.
git -C "$KC/repo" remote add origin https://github.com/acme/widget.git
cp "$HERE"/*.sh "$KC/harness/"; cp "$HERE"/*.sh "$KC/o/"
# Same fixture requirement as §16e: cmd_check also judges DISPATCH PROVISIONING (#1736), so the
# repo must carry a pre-flight tool or the key verdicts below are never reached.
mkdir -p "$KC/repo/tools"; : > "$KC/repo/tools/collision_preflight.py"
# #1717: cmd_check refuses a cell without the record step, and every check in 16f drives cmd_check.
mkdir -p "$KC/home/.pi/agent/scripts"
printf '#!/bin/bash\nexit 0\n' > "$KC/home/.pi/agent/scripts/record-review.sh"
chmod +x "$KC/home/.pi/agent/scripts/record-review.sh"
# #1717: the recorder's declared sibling must sit beside it, or cmd_check refuses the cell.
mkdir -p "$KC/home/.pi/agent/scripts/lib"
printf '#!/usr/bin/env python3\n' > "$KC/home/.pi/agent/scripts/lib/diff-normalize.py"
printf 'AI_REVIEW_GATE_KEY=FILEKEY\n' > "$KC/home/keys.env"; : > "$KC/home/keys-empty.env"
kc_check() {  # $1 = ENV_FILE, $2 = extra env assignment for the supervisor's own shell ('' = none)
  if [ -n "$2" ]; then
    env "$2" PATH="$STUB_TM:$GSTUB:$PATH" HOME="$KC/home" CELL_HOME="$KC/home" REPO="$KC/repo" \
      O="$KC/o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 ENV_FILE="$1" bash "$HERE/../cloud-cell-supervisor.sh" check 2>&1
  else
    PATH="$STUB_TM:$GSTUB:$PATH" HOME="$KC/home" CELL_HOME="$KC/home" REPO="$KC/repo" \
      O="$KC/o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 ENV_FILE="$1" bash "$HERE/../cloud-cell-supervisor.sh" check 2>&1
  fi
}
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys.env" '' )"
case "$out" in *'merge authority key present'*) rc=0 ;; *) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; esac
ck "cmd_check reports the key present when keys.env carries it" $rc
out="$(kc_check "$KC/home/keys-empty.env" 'AI_REVIEW_GATE_KEY=AMBIENT')"
case "$out" in *'will NOT receive it'*) rc=0 ;; *) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; esac
ck "cmd_check warns that an ambient-only key does not reach the session" $rc
# An EMPTY assignment matches a textual grep but sources to empty, which downstream treats as
# absent — so it must not be reported present (a false green on a cell that cannot merge).
printf 'AI_REVIEW_GATE_KEY=\n' > "$KC/home/keys-empty-key.env"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-empty-key.env" '' )"
case "$out" in *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; *) rc=0 ;; esac
ck "an EMPTY key in keys.env is NOT reported present" $rc
# The start path is the ONLY path that starts a cell, so it must not swallow the verdict: an
# operator who exported the key ambiently gets a keyless cell and no signal otherwise.
rm -f "$TMP/tm/up" "$TMP/tm/cmd" "$TMP/tm/names"
serr="$( AI_REVIEW_GATE_KEY=AMBIENT PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$KC/home" CELL_HOME="$KC/home" \
    REPO="$KC/repo" O="$KC/o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 ENV_FILE="$KC/home/keys-empty.env" SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" start 2>&1 >/dev/null )"
case "$serr" in *'will NOT receive it'*"$KC/home/.pi/agent/.ai-review-gate-key"*) rc=0 ;; *) rc=1; echo "      stderr: $(printf '%s' "$serr" | tail -2)" ;; esac
ck "the start path surfaces an ambient-only key verdict on stderr" $rc
# ... and the OTHER branch: an empty keys.env with NO ambient key must also reach start's stderr
# (filtering on just the two easy-to-grep verdicts left this one silent).
rm -f "$TMP/tm/up" "$TMP/tm/cmd" "$TMP/tm/names"
serr2="$( unset AI_REVIEW_GATE_KEY; PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$KC/home" CELL_HOME="$KC/home" \
    REPO="$KC/repo" O="$KC/o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 ENV_FILE="$KC/home/keys-empty-key.env" SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" start 2>&1 >/dev/null )"
case "$serr2" in *'AI_REVIEW_GATE_KEY'*) rc=0 ;; *) rc=1; echo "      stderr: $(printf '%s' "$serr2" | tail -2)" ;; esac
ck "the start path surfaces the no-key verdict on stderr" $rc
# A whitespace-only key FILE is not a key either (the consumer strips whitespace).
mkdir -p "$KC/home/.pi/agent"; printf '\n' > "$KC/home/.pi/agent/.ai-review-gate-key"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-empty-key.env" '' )"
rm -f "$KC/home/.pi/agent/.ai-review-gate-key"
case "$out" in *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; *) rc=0 ;; esac
ck "cmd_check does not bless a WHITESPACE-ONLY key file" $rc
# A WHITESPACE-ONLY value in keys.env is the same false green one step earlier: the consumer
# strips whitespace, and because the raw value is non-empty it never falls back to the key FILE.
# cmd_check must judge it absent (not "present in $ENV_FILE").
printf 'AI_REVIEW_GATE_KEY="   "\n' > "$KC/home/keys-ws-value.env"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-ws-value.env" '' )"
case "$out" in
  *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;;
  # The verdict must name the path the check ACTUALLY reads: the message is the operator's only
  # instruction, and on a real cell $HOME is not $CELL_HOME, so "~/.pi/..." would send them to a home
  # the session never reads.
  *'WHITESPACE-ONLY'*"$KC/home/.pi/agent/.ai-review-gate-key"*) rc=0 ;;
  *) rc=1; echo "      no whitespace verdict naming the path: $(printf '%s' "$out" | tail -2)" ;;
esac
ck "a WHITESPACE-ONLY key in keys.env is not reported present, and is named" $rc
# …and it SHADOWS a valid key file (the consumer's fallback is on the raw value), so a real file
# must not turn that same verdict green.
printf 'FILEKEY\n' > "$KC/home/.pi/agent/.ai-review-gate-key"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-ws-value.env" '' )"
rm -f "$KC/home/.pi/agent/.ai-review-gate-key"
case "$out" in *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; *) rc=0 ;; esac
ck "a WHITESPACE-ONLY key in keys.env shadows a valid key file" $rc
# The start path must surface that verdict too: it starts the cell either way, and it is the only
# signal the operator gets.
rm -f "$TMP/tm/up" "$TMP/tm/cmd" "$TMP/tm/names"
serr3="$( unset AI_REVIEW_GATE_KEY; PATH="$TM:$PATH" TM_STATE="$TMP/tm" HOME="$KC/home" CELL_HOME="$KC/home" \
    REPO="$KC/repo" O="$KC/o" HARNESS="$HFIX_H" HARNESS_REPO="$HFIX" HARNESS_REF=origin/main HARNESS_FETCH=0 ENV_FILE="$KC/home/keys-ws-value.env" SCOPE=own \
    bash "$HERE/../cloud-cell-supervisor.sh" start 2>&1 >/dev/null )"
case "$serr3" in *'WHITESPACE-ONLY'*"$KC/home/.pi/agent/.ai-review-gate-key"*) rc=0 ;; *) rc=1; echo "      stderr: $(printf '%s' "$serr3" | tail -2)" ;; esac
ck "the start path surfaces the whitespace-only key verdict on stderr" $rc
# keys.env may set HOME, and the supervisor re-exports HOME=$CELL_HOME AFTER sourcing — so the key
# verdict must not depend on which home a keys.env HOME= line points at. (Full disclosure: with that
# re-export in place ${HOME} and $CELL_HOME are the same value, so this pins the BEHAVIOUR, not the
# spelling — a mutant that reads ${HOME} is equivalent and stays green, by design.)
KH="$KC/other-home"; mkdir -p "$KH/.pi/agent"; printf 'FILEKEY\n' > "$KH/.pi/agent/.ai-review-gate-key"
printf 'HOME=%s\n' "$KH" > "$KC/home/keys-home.env"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-home.env" '' )"
case "$out" in *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; *) rc=0 ;; esac
ck "a keys.env HOME= does not make the key verdict green (it reads \$CELL_HOME)" $rc
# …and the mirror image of the SAME divergence, so the pair discriminates in both directions: a
# keys.env HOME= pointing at a directory WITHOUT a key must not hide the key that IS in $CELL_HOME.
# (Setting HOME in the helper's env cannot discriminate: the supervisor re-exports HOME=$CELL_HOME
# before sourcing, so ONLY a keys.env HOME= can make the two differ — which is why both halves are
# driven through the file. A $HOME passed as an env prefix passes on the pre-fix code too.)
printf 'FILEKEY\n' > "$KC/home/.pi/agent/.ai-review-gate-key"
mkdir -p "$KC/no-key-home"
printf 'HOME=%s\n' "$KC/no-key-home" > "$KC/home/keys-other-home.env"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-other-home.env" '' )"
rm -f "$KC/home/.pi/agent/.ai-review-gate-key"
case "$out" in *'merge authority key present'*) rc=0 ;; *) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;; esac
ck "a keys.env HOME= without a key does not hide the key in \$CELL_HOME" $rc
# A value of exactly ONE NEWLINE is whitespace-only for the consumer (it strips whitespace) but
# NON-EMPTY for its raw test, so the consumer takes the env branch and never reads the key file.
# `$( )` strips trailing newlines, so a capture-based test reads this as "no env value" and the
# file branch answers — the divergence that made a keyless cell read as present.
printf 'AI_REVIEW_GATE_KEY="\n"\n' > "$KC/home/keys-nl.env"
printf 'FILEKEY\n' > "$KC/home/.pi/agent/.ai-review-gate-key"
out="$( unset AI_REVIEW_GATE_KEY; kc_check "$KC/home/keys-nl.env" '' )"
rm -f "$KC/home/.pi/agent/.ai-review-gate-key"
case "$out" in
  *'merge authority key present'*) rc=1; echo "      out: $(printf '%s' "$out" | tail -2)" ;;
  *'WHITESPACE-ONLY'*) rc=0 ;;
  *) rc=1; echo "      no whitespace verdict: $(printf '%s' "$out" | tail -2)" ;;
esac
ck "a NEWLINE-ONLY key in keys.env is judged whitespace-only, not present via the file" $rc
# The gh-credential lookup is HOME-dependent (`gh` reads $HOME/.config/gh), and keys.env may carry
# a HOME= line — so the preflight must ask that question under the SAME home the session will use
# ($CELL_HOME, forced by the session command). Sourcing keys.env last left cmd_check validating a
# home the session never uses: credentials there made it say "ok: gh auth" and the cell started,
# after which every gh call in the session failed.
printf 'HOME=%s\n' "$KH" > "$KC/home/keys-home2.env"
GH_HOME_RECORD="$TMP/gh-home.txt"; rm -f "$GH_HOME_RECORD"; export GH_HOME_RECORD
kc_check "$KC/home/keys-home2.env" '' >/dev/null 2>&1 || true
unset GH_HOME_RECORD
if [ -s "$TMP/gh-home.txt" ]; then
  [ "$(cat "$TMP/gh-home.txt")" = "$KC/home" ] && rc=0 || { rc=1; echo "      gh saw HOME=$(cat "$TMP/gh-home.txt"), cell home is $KC/home"; }
else
  rc=1; echo "      gh was never invoked with a recorded HOME"
fi
ck "cmd_check runs gh under \$CELL_HOME, not a keys.env HOME=" $rc
# The SAME divergence exists in cloud-cell-bringup.sh (it sources keys.env and runs check_gh
# afterwards), and it has no other guard at all — deleting its re-export left the suite green.
# Driven for real: the script's own flow with stub tools, and the gh stub records the HOME that
# `auth status` ran under.
BG="$TMP/bg"; mkdir -p "$BG/stub" "$BG/home/.pi/agent" "$BG/otherhome"
git init -q "$BG/work" 2>/dev/null || true
cat > "$BG/stub/gh" <<'GHSTUB'
#!/bin/bash
case "$*" in
  *"auth status"*) [ -n "${GH_HOME_RECORD:-}" ] && printf '%s\n' "$HOME" >> "$GH_HOME_RECORD"; exit 0 ;;
  *"api user"*) echo tester; exit 0 ;;
  *"api repos/"*) echo true; exit 0 ;;
esac
exit 0
GHSTUB
printf '#!/bin/bash\necho 200\n' > "$BG/stub/curl"
printf '#!/bin/bash\necho LANE_READY\n' > "$BG/stub/pi"
printf '#!/bin/bash\nshift; exec "$@"\n' > "$BG/stub/timeout"
printf '#!/bin/bash\nexit 0\n' > "$BG/stub/docker"
# ⛔ `uv` and `tmux` are REQUIRED BY cloud-cell-bringup.sh's own toolchain check
# (`check_tools`: `for c in git gh node python3 uv tmux`), so they must be stubbed here exactly
# like the tools above. Without them this check passes ONLY on a box that happens to have both,
# and the shard is RED on the Linux CI runner — the ubuntu-24.04 image ships neither (verified
# against actions/runner-images Ubuntu2404-Readme.md, which lists no `uv` and no `tmux`). That is
# the measured difference between a dev container (selftest.sh 330/0) and `bash-suites` on
# agent-infra#1769 (`==> 328 passed, 2 failed`, both bringup checks): a platform-dependent
# dependency smuggled into the shard list BOTH lanes run, which is the #1369 class itself.
printf '#!/bin/bash\nprintf "uv 0.0.0-stub\\n"\n' > "$BG/stub/uv"
printf '#!/bin/bash\nexit 0\n' > "$BG/stub/tmux"
chmod +x "$BG/stub/"*
printf 'HOME=%s\nDEEPSEEK_API_KEY=sk-test\n' "$BG/otherhome" > "$BG/home/keys.env"
GH_HOME_RECORD="$TMP/bg-gh-home.txt"; rm -f "$GH_HOME_RECORD"
GH_HOME_RECORD="$GH_HOME_RECORD" PATH="$BG/stub:$PATH" CELL_HOME="$BG/home" REPO_SLUG=acme/widget \
  WORKDIR="$BG/work" ENV_FILE= GH_TOKEN_FILE="$TMP/gh-tok" \
  bash "$HERE/../cloud-cell-bringup.sh" --check > "$TMP/bg.out" 2>&1 || true
if [ -s "$TMP/bg-gh-home.txt" ]; then
  [ "$(cat "$TMP/bg-gh-home.txt")" = "$BG/home" ] && rc=0 || { rc=1; echo "      bringup's gh saw HOME=$(cat "$TMP/bg-gh-home.txt"), cell home is $BG/home"; }
else
  rc=1; echo "      bringup never ran gh auth status"
fi
ck "cloud-cell-bringup runs gh under \$CELL_HOME, not a keys.env HOME=" $rc
# …and with no ENV_FILE it must resolve the default UNDER $CELL_HOME, not the hard-coded
# /tmp/cell-home path it used to name — otherwise it validates and sources a file the cell never
# reads, and a stale one there would false-green the bring-up.
case "$(cat "$TMP/bg.out")" in
  *"sourced $BG/home/keys.env"*) rc=0 ;;
  *) rc=1; echo "      bringup did not source \$CELL_HOME/keys.env ($(grep -c . "$TMP/bg.out") output lines)" ;;
esac
ck "cloud-cell-bringup resolves the default keys.env under \$CELL_HOME" $rc

# ── 17) the daemon PATH never contains a shim / ~/.pi directory ──────────────────
# macOS TCC blocks LAUNCHD from reading ~/Documents, so ~/.pi/agent/shims/gh (a symlink into
# ~/Documents) is EPERM under the daemon ("Operation not permitted") even though it runs fine in
# this interactive shell — which is why the install.sh probe-by-execution reports a FALSE GREEN.
# The guard is the exclusion in add_dir(), so DRIVE THE SHIPPED PATH CODE (extracted, not
# re-implemented): put a shim FIRST on the driving PATH, render DAEMON_PATH, and assert no shim/
# ~/.pi directory survives while the real binary's directory is kept. A pre-fix add_dir fixture
# proves the scenario is real and that dropping the exclusion would fail this check.
unset -f gh pi uv tmux 2>/dev/null || true   # an exported function would shadow the stubs below
awk '/^add_dir\(\) \{/{f=1} f{ if (/^ok "daemon PATH:/) exit; print }' "$INST" > "$TMP/daemonpath.sh"
if need "$TMP/daemonpath.sh" "the daemon-PATH block is extracted from the shipped install.sh"; then
  DP="$TMP/dp"; mkdir -p "$DP/home/.pi/agent/shims" "$DP/realbin"
  # the shim lives under a ~/.pi/.../shims path (exactly the shape TCC refuses); the REAL binary
  # lives in a plain directory that matches none of the excluded patterns.
  printf '#!/bin/bash\nprintf "gh 9.9.9 (shim)\\n"\n' > "$DP/home/.pi/agent/shims/gh"
  printf '#!/bin/bash\nprintf "gh 9.9.9 (real)\\n"\n' > "$DP/realbin/gh"
  chmod +x "$DP/home/.pi/agent/shims/gh" "$DP/realbin/gh"
  DRIVE_PATH="$DP/home/.pi/agent/shims:$DP/realbin:/usr/bin:/bin"
  pre="$(HOME="$DP/home" PATH="$DRIVE_PATH" command -v gh)"
  [ "$pre" = "$DP/home/.pi/agent/shims/gh" ] && rc=0 || { rc=1; echo "      'gh' resolved to '$pre'"; }
  ck "non-vacuity: 'gh' on the driving PATH resolves through the shim" $rc
  { echo 'set -u'; cat "$TMP/daemonpath.sh"; echo 'printf "%s\\n" "$DAEMON_PATH"'; } > "$DP/drive.sh"
  bash -n "$DP/drive.sh" && rc=0 || rc=1
  ck "the daemon-PATH driver parses" $rc
  out="$(HOME="$DP/home" PATH="$DRIVE_PATH" bash "$DP/drive.sh")"
  case "$out" in *"/shims"*|*"/.pi/"*) rc=1; echo "      daemon PATH: $out";; *) rc=0;; esac
  ck "the daemon PATH contains no */shims or */.pi/* directory" $rc
  case ":$out:" in *":$DP/realbin:"*) rc=0;; *) rc=1; echo "      daemon PATH: $out";; esac
  ck "the daemon PATH keeps the real binary's directory (the shim is dropped, not the tool)" $rc
  res="$(PATH="$out" command -v gh)"
  # The base DAEMON_PATH prefix is hardcoded and may hold a real gh on a brew box, so the invariant
  # is "resolves to a REAL executable, not the shim" — asserting equality with the fixture's realbin
  # over-specifies which of two real binaries wins and false-reds a `brew install gh` box.
  case "$res" in ""|"$DP/home/.pi/agent/shims/gh") rc=1;; *) [ -x "$res" ] && rc=0 || rc=1;; esac
  ck "under the daemon PATH, gh resolves to a real (non-shim) executable" $rc
  # Non-vacuity: the PRE-FIX add_dir (no exclusion) does bake the shim dir into the PATH.
  cat > "$DP/prefix-add_dir.sh" <<'SH'
add_dir() {
  case "$1" in /*) ;; *) return 0 ;; esac
  case ":$DAEMON_PATH:" in *":$1:"*) ;; *) DAEMON_PATH="$DAEMON_PATH:$1" ;; esac
}
DAEMON_PATH="/usr/bin:/bin"
p="$(command -v gh)"; add_dir "$(cd "$(dirname "$p")" && pwd)"
printf '%s\n' "$DAEMON_PATH"
SH
  old="$(HOME="$DP/home" PATH="$DRIVE_PATH" bash "$DP/prefix-add_dir.sh")"
  case "$old" in *"/shims"*) rc=0;; *) rc=1; echo "      pre-fix PATH: $old";; esac
  ck "non-vacuity: the pre-fix add_dir really admitted the shim dir" $rc
  # A PATH entry that is a SYMLINK to the shim directory must not slip past a name-only match,
  # and must not suppress the real binary (the resolve-past loop keys off the same test).
  ln -s "$DP/home/.pi/agent/shims" "$DP/shims-link"
  LINK_PATH="$DP/shims-link:$DP/realbin:/usr/bin:/bin"
  out2="$(HOME="$DP/home" PATH="$LINK_PATH" bash "$DP/drive.sh")"
  case "$out2" in *"/shims"*|*"/.pi/"*) rc=1; echo "      symlinked-shim daemon PATH: $out2";; *) rc=0;; esac
  ck "a symlink TO the shim dir cannot enter the daemon PATH" $rc
  case ":$out2:" in *":$DP/realbin:"*) rc=0;; *) rc=1; echo "      symlinked-shim daemon PATH: $out2";; esac
  ck "a symlinked shim dir does not suppress the real binary's directory" $rc
  # An EXPORTED `gh` function must not hide the real binary's directory: `type -P` ignores functions
  # (a function is not what launchd execs), so resolution still finds realbin.
  fnout="$( unset -f gh; gh() { exit 0; }; export -f gh; HOME="$DP/home" PATH="$DRIVE_PATH" bash "$DP/drive.sh" )"
  case ":$fnout:" in *":$DP/realbin:"*) rc=0;; *) rc=1; echo "      function-perturbed daemon PATH: $fnout";; esac
  ck "an exported 'gh' function does not hide the real binary's directory" $rc
fi

# ── 18) the install-time probe EXECUTES every tool, not just resolves it ────────
# Resolving a name is not running it: a shim/wrapper directory that does NOT match the exclusion
# patterns (cmux's `cmux-cli-shims` is a real one on this box) resolves the tool to a wrapper that
# exits 127, and a resolution-only probe reports install success while every lane spawn then fails.
# Drive the SHIPPED probe block with a fixture whose `pi` resolves but cannot run.
awk '/^for bin in tmux uv pi gh jq cmux; do$/{f=1} f{print} f&&/^done$/{exit}' "$INST" > "$TMP/probe.sh"
if need "$TMP/probe.sh" "the install-time probe is extracted from the shipped install.sh"; then
  PB="$TMP/probe"; mkdir -p "$PB/bin"
  for b in tmux uv gh jq; do printf '#!/bin/bash\nexit 0\n' > "$PB/bin/$b"; chmod +x "$PB/bin/$b"; done
  # ⛔ The driver runs under install.sh's OWN shell options (`set -euo pipefail`, line 12), not a
  # weaker `set -u`: `_p="$(… || true)"` is reached only because install.sh runs under errexit, and
  # a `set -u`-only driver cannot see the unguarded-assignment regression it exists to pin.
  { echo 'set -euo pipefail'; echo 'die() { echo "DIED: $*" >&2; exit 9; }'; echo 'warn() { echo "WARN: $*" >&2; }'; cat "$TMP/probe.sh"; } > "$PB/drive.sh"
  bash -n "$PB/drive.sh" && rc=0 || rc=1
  ck "the probe driver parses" $rc
  printf '#!/bin/bash\nexit 127\n' > "$PB/bin/pi"; chmod +x "$PB/bin/pi"
  PATH="$PB/bin:/usr/bin:/bin" DAEMON_PATH="$PB/bin" bash "$PB/drive.sh" >/dev/null 2>&1; rc=$?
  [ "$rc" = "9" ] && rc=0 || { rc=1; echo "      probe rc=$rc (expected 9 — a resolved-but-non-running pi must fail install)"; }
  ck "the probe fails install when a resolved tool cannot RUN (exit 127)" $rc
  printf '#!/bin/bash\nexit 0\n' > "$PB/bin/pi"; chmod +x "$PB/bin/pi"
  PATH="$PB/bin:/usr/bin:/bin" DAEMON_PATH="$PB/bin" bash "$PB/drive.sh" >/dev/null 2>&1; rc=$?
  [ "$rc" = "0" ] && rc=0 || { rc=1; echo "      probe rc=$rc (expected 0 when every resolved tool runs)"; }
  ck "the probe passes when every resolved tool runs" $rc
  # ⛔ cmux IS A PROBE ENTRY BECAUSE ITS ABSENCE IS SILENT AND TOTAL. The pre-flight's holder surface
  # reads the fleet board's live-session store through `cmux sessions list`; an unrunnable cmux leaves
  # `liveness_measured` False, the board carrying `orphans[kind=liveness-unmeasured]`, and EVERY
  # candidate INCOMPLETE — so the refresh aborts by design (#1736) and the backlog drains to 0. A box
  # with NO cmux never reaches the branch (`command -v` skips it); one that HAS it must be able to RUN
  # it, which is the shim/wrapper case this probe exists for.
  printf '#!/bin/bash\nexit 0\n' > "$PB/bin/cmux"; chmod +x "$PB/bin/cmux"
  PATH="$PB/bin:/usr/bin:/bin" DAEMON_PATH="$PB/bin" bash "$PB/drive.sh" >/dev/null 2>&1; rc=$?
  [ "$rc" = "0" ] && rc=0 || { rc=1; echo "      probe rc=$rc (expected 0 — a runnable cmux must not fail the install)"; }
  ck "the probe passes when a resolved cmux RUNS" $rc
  printf '#!/bin/bash\nexit 127\n' > "$PB/bin/cmux"; chmod +x "$PB/bin/cmux"
  PATH="$PB/bin:/usr/bin:/bin" DAEMON_PATH="$PB/bin" bash "$PB/drive.sh" >/dev/null 2>&1; rc=$?
  [ "$rc" = "9" ] && rc=0 || { rc=1; echo "      probe rc=$rc (expected 9 — a resolved-but-non-running cmux would certify nothing)"; }
  ck "the probe fails install when a resolved cmux cannot RUN (nothing could be queued)" $rc
  rm -f "$PB/bin/cmux"
  # An EXPORTED shell function named `gh` must NOT satisfy the probe: `command -v` reports it, but a
  # function is not what launchd execs and the daemon PATH has no gh binary at all.
  PB2="$PB/bin2"; mkdir -p "$PB2"
  for b in tmux uv pi jq; do printf '#!/bin/bash\nexit 0\n' > "$PB2/$b"; chmod +x "$PB2/$b"; done
  ( unset -f gh pi uv tmux; gh() { exit 0; }; export -f gh; \
    PATH="$PB2:/usr/bin:/bin" DAEMON_PATH="$PB2" bash "$PB/drive.sh" ) >/dev/null 2>&1; rc=$?
  [ "$rc" = "9" ] && rc=0 || { rc=1; echo "      probe rc=$rc (expected 9 — an exported gh FUNCTION is not a daemon binary)"; }
  ck "an exported shell function does not satisfy the probe" $rc
  # A wrapper that DELEGATES by name must not pass because the AMBIENT PATH can satisfy it: the
  # probe must execute under $DAEMON_PATH, where nothing can (the false green one layer in).
  PB3="$PB/w3"; mkdir -p "$PB3/shared" "$PB3/wrap" "$PB3/real" "$PB3/base"
  for b in tmux uv gh jq; do printf '#!/bin/bash\nexit 0\n' > "$PB3/shared/$b"; chmod +x "$PB3/shared/$b"; done
  printf '#!/bin/bash\nexit 0\n' > "$PB3/real/pi"; chmod +x "$PB3/real/pi"
  cat > "$PB3/wrap/pi" <<'SH'
#!/bin/bash
self="$(cd "${0%/*}" && pwd)"
found=""
IFS=:
for d in $PATH; do
  d="$(cd "$d" 2>/dev/null && pwd)" || continue
  [ "$d" = "$self" ] && continue
  [ -x "$d/pi" ] && { found="$d/pi"; break; }
done
[ -n "$found" ] && exec "$found" "$@"
exit 127
SH
  chmod +x "$PB3/wrap/pi"
  ( unset -f gh pi uv tmux; \
    PATH="$PB3/shared:$PB3/wrap:$PB3/real:/usr/bin:/bin" DAEMON_PATH="$PB3/base:$PB3/shared:/usr/bin:/bin:$PB3/wrap" bash "$PB/drive.sh" ) >/dev/null 2>&1; rc=$?
  [ "$rc" = "9" ] && rc=0 || { rc=1; echo "      probe rc=$rc (expected 9 — a name-delegating wrapper must fail under the daemon PATH)"; }
  ck "a name-delegating wrapper is probed under the daemon PATH, not the ambient one" $rc
fi

# ── load gate: an agent spawn must not be piled onto a post-boot indexing storm ──
# Driven, not grep'd: a text-presence check passes against a build with the gate neutered to
# `can_spawn() { true; }` — reproduced before this version replaced it.
# ⛔ AND SINCE #1732 THE SPAWN GATE HAS A SECOND DIMENSION, so the extraction takes BOTH halves.
# Against the pre-fix tree TEN checks below fail — SIX `MEMAVAIL_MB` cases (the shipped `can_spawn`
# there reads `L` alone, so a box with 100M available and load 3 still spawns), the order assertion,
# the evidence-token count, and the two extraction checks for `spawn_gate_tok()`/`measure_mem()` — on
# a log where every pre-existing load case still passes (measured: 462 passed / 10 failed on
# `origin/main`, 475 passed / 0 failed on the fixed tree). That is the reproduction: the new checks
# bite, and nothing old was weakened.
grep -m1 '^can_spawn() {' "$LOOP" > "$TMP/canspawn.sh"
grep -m1 '^mem_spawn_ok() {' "$LOOP" >> "$TMP/canspawn.sh"
if need "$TMP/canspawn.sh" "can_spawn() is extracted from the shipped loop"; then
  MAX_LOAD=16; MIN_MEM_FREE_MB=512
  # An AMPLE reading is the baseline for the load cases: memory must not mask a load assertion
  # (both halves are ANDed, so a missing reading would refuse every case below and the load
  # assertions would "pass" for the wrong reason).
  MEMAVAIL_MB=9000; MEM_UNKNOWN=0
  . "$TMP/canspawn.sh"
  L=0;   can_spawn && rc=0 || rc=1; ck "shipped can_spawn(): load 0 < 16 -> spawn allowed" $rc
  L=15;  can_spawn && rc=0 || rc=1; ck "shipped can_spawn(): load 15 < 16 -> spawn allowed" $rc
  L=16;  can_spawn && rc=1 || rc=0; ck "shipped can_spawn(): load 16 -> spawn held back" $rc
  L=221; can_spawn && rc=1 || rc=0; ck "shipped can_spawn(): load 221 (post-boot storm) -> held back" $rc
  L="";  can_spawn && rc=0 || rc=1; ck "shipped can_spawn(): unset load defaults to 0 (documented fail-open)" $rc
  # ── the MEMORY arm (#1732): available memory below the floor refuses at a calm load ──
  L=3
  MEMAVAIL_MB=513; MEM_UNKNOWN=0; can_spawn && rc=0 || rc=1
  ck "shipped can_spawn(): mem 513M > floor 512M at load 3 -> spawn allowed" $rc
  MEMAVAIL_MB=512; MEM_UNKNOWN=0; can_spawn && rc=1 || rc=0
  ck "shipped can_spawn(): mem 512M == floor (the dispatch gate's own boundary) -> held back" $rc
  MEMAVAIL_MB=100; MEM_UNKNOWN=0; can_spawn && rc=1 || rc=0
  ck "shipped can_spawn(): mem 100M < floor 512M at load 3 -> held back" $rc
  MEMAVAIL_MB=653; MEM_UNKNOWN=0; MIN_MEM_FREE_MB=700; can_spawn && rc=1 || rc=0
  ck "shipped can_spawn(): a raised MIN_MEM_FREE_MB binds the spawn sites (653M < 700M) -> held back" $rc
  # UNKNOWN is not ample, and it must hold even with a STALE ample number beside it: that is the
  # shape a failed probe leaves behind in any tree where the two are not set together.
  MIN_MEM_FREE_MB=512
  MEMAVAIL_MB=9000; MEM_UNKNOWN=1; can_spawn && rc=1 || rc=0
  ck "shipped can_spawn(): MEM_UNKNOWN=1 with a stale ample reading -> held back (unknown is not ample)" $rc
  MEMAVAIL_MB=""; MEM_UNKNOWN=0; can_spawn && rc=1 || rc=0
  ck "shipped can_spawn(): unset MEMAVAIL_MB -> held back (fail-CLOSED, unlike the load fail-open)" $rc
  MEMAVAIL_MB="garbage"; MEM_UNKNOWN=0; can_spawn && rc=1 || rc=0
  ck "shipped can_spawn(): non-numeric MEMAVAIL_MB -> held back (an errored comparison must not open the gate)" $rc
fi
# ⛔ THE READING MUST BE TAKEN BEFORE THE SITES THAT READ IT (#1732). This is the half a behavioural
# test on the extracted function CANNOT see: `measure_mem` used to run only in the [cap] block, which
# sits BELOW all six spawn sites, so a `can_spawn` that consults MEMAVAIL_MB there would decide on the
# previous cycle's figure (and on cycle 1, on nothing at all) — while every unit case above passes.
# Assert the ORDER in the shipped file: the prologue call precedes the first spawn site.
_mm_line=$(grep -n '^  measure_mem$' "$LOOP" | head -1 | cut -d: -f1)
_site_line=$(grep -nE '&& can_spawn' "$LOOP" | head -1 | cut -d: -f1)
if [ -n "$_mm_line" ] && [ -n "$_site_line" ] && [ "$_mm_line" -lt "$_site_line" ]; then rc=0; else
  rc=1; echo "      measure_mem at '${_mm_line:-<none>}', first can_spawn site at '${_site_line:-<none>}'"
fi
ck "the shipped loop MEASURES memory before the first spawn site reads it (line $_mm_line < $_site_line)" $rc
# ⛔ A HELD-BACK SPAWN MUST NAME THE ARM THAT HELD IT (#1732). The five slot refusals printed
# `load-gate=<L>/<MAX>` only, which was complete while load WAS the gate; with a memory arm it reads as
# a load refusal. Assert both halves: every refusal site prints the token, and the token spells out an
# UNKNOWN probe instead of printing a `0M` that looks like a measurement.
_slot_n=$(grep -cE 'but NO [a-z-]+ slot \(' "$LOOP")
_slot_t=$(grep -E 'but NO [a-z-]+ slot \(' "$LOOP" | grep -cF '$(spawn_gate_tok)')
# ⛔ ANCHORED TO THE REFUSAL LINES, NOT A FILE-WIDE COUNT (review, #1732). A bare `grep -c` of the
# token is satisfied by a COMMENT that mentions it — and this very function's comment block discusses
# the token, so a decoy there would keep the check green while a real refusal line lost its evidence.
# The comment 40 lines below names the same class; this is it.
# 5 -> 6 for agent-infra#2653: the review arm gained a refusal for a head that HAS findings at a full
# fixer ceiling. It names the FIX side (a fixer is the remedy there, never a review), and it carries the
# same gate token because the same two gates can have held the spawn.
[ "$_slot_n" = "6" ] && [ "$_slot_t" = "$_slot_n" ] && rc=0 || { rc=1; echo "      $_slot_t of $_slot_n refusal line(s) print the token (expected 6 of 6)"; }
ck "all six held-back-spawn lines print the gate evidence token (load-gate + mem-gate)" $rc
sed -n '/^spawn_gate_tok() {/,/^}/p' "$LOOP" > "$TMP/spawntok.sh"
if need "$TMP/spawntok.sh" "spawn_gate_tok() is extracted from the shipped loop"; then
  got="$(bash -c '. "$1"; L=3; MAX_LOAD=40; MIN_MEM_FREE_MB=512; MEMAVAIL_MB=100; MEM_UNKNOWN=0; spawn_gate_tok' _ "$TMP/spawntok.sh")"
  [ "$got" = "load-gate=3/40 mem-gate=100M/512" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "shipped spawn_gate_tok(): prints the READING and the FLOOR for both arms" $rc
  got="$(bash -c '. "$1"; L=3; MAX_LOAD=40; MIN_MEM_FREE_MB=512; MEMAVAIL_MB=0; MEM_UNKNOWN=1; spawn_gate_tok' _ "$TMP/spawntok.sh")"
  [ "$got" = "load-gate=3/40 mem-gate=UNKNOWN/512" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "shipped spawn_gate_tok(): a FAILED probe prints UNKNOWN, not a 0M that reads as a measurement" $rc
fi
# ...and the measurement's own failure polarity, driven: a probe that cannot answer must ZERO the
# reading and set UNKNOWN, which is what makes the fail-closed claim above independent of MEM_UNKNOWN.
sed -n '/^measure_mem() {/,/^}/p' "$LOOP" > "$TMP/measuremem.sh"
if need "$TMP/measuremem.sh" "measure_mem() is extracted from the shipped loop"; then
  { grep -m1 '^is_num() {' "$LOOP"; cat "$TMP/measuremem.sh"; } > "$TMP/measuremem-full.sh"
  got="$(bash -c '. "$1"; mem_avail_mb() { return 1; }; MEMAVAIL_MB=9000; MEM_UNKNOWN=0; measure_mem; printf "%s %s" "$MEMAVAIL_MB" "$MEM_UNKNOWN"' _ "$TMP/measuremem-full.sh")"
  [ "$got" = "0 1" ] && rc=0 || { rc=1; echo "      got '$got' (expected '0 1')"; }
  ck "shipped measure_mem(): a FAILED probe zeroes the reading and sets MEM_UNKNOWN" $rc
  got="$(bash -c '. "$1"; mem_avail_mb() { printf "garbage\\n"; }; MEMAVAIL_MB=9000; MEM_UNKNOWN=0; measure_mem; printf "%s %s" "$MEMAVAIL_MB" "$MEM_UNKNOWN"' _ "$TMP/measuremem-full.sh")"
  [ "$got" = "0 1" ] && rc=0 || { rc=1; echo "      got '$got' (expected '0 1')"; }
  ck "shipped measure_mem(): a NON-NUMERIC probe zeroes the reading and sets MEM_UNKNOWN" $rc
  got="$(bash -c '. "$1"; mem_avail_mb() { printf "4096\\n"; }; MEMAVAIL_MB=0; MEM_UNKNOWN=1; measure_mem; printf "%s %s" "$MEMAVAIL_MB" "$MEM_UNKNOWN"' _ "$TMP/measuremem-full.sh")"
  [ "$got" = "4096 0" ] && rc=0 || { rc=1; echo "      got '$got' (expected '4096 0')"; }
  ck "shipped measure_mem(): a GOOD probe clears MEM_UNKNOWN and publishes the reading" $rc
fi
# Assert each spawn SITE, not a count — a count is satisfied by decoy comments,
# which is exactly how an earlier version of this check passed against a stripped build.
# NOTE (#1764): the `^merge-` selector now appears at TWO sites — the gate-mode re-record spawn
# and the rail-mode GREEN spawn (`merge-one.sh` is the worker for both) — so the expectation is 2.
# NOTE (#2223): the `^fix-` selector now appears at THREE SPAWN sites — conflict, CI-red, and the
# RED-FIXER (a rail refusal that names a red tree). The count is pinned rather than tested loosely,
# which is the point: a fourth fixer spawn added without a load gate must redden this line.
# ⛔ SPAWN SITES AND CI-QUEUE DEFER ARMS ARE COUNTED SEPARATELY, AND IN BOTH DIRECTIONS.
# ⛔ THE FIXER DEFER COUNT IS NOW ZERO ON PURPOSE (#2927). The three fixer spawn sites used to nest a
# `ciq_push_ok` deferral inside their own eligibility. They no longer do: a fixer is REPAIR — it acts
# on a PR that already exists — so the class rule in ci-queue.sh's header excludes it from queue
# gating. ⛔ NOT because "its pass is already spent" (a repair push DOES start a fresh run): the basis
# is #2927's decision plus the measurement that the NUMBER was demand read as supply. Measured 2026-10-27 on cell 4, that gate skipped 41
# consecutive repair dispatches while 8 self-hosted runners and ~11 lane slots sat idle, against a
# queue depth that belonged to GitHub-HOSTED concurrency and to NEW-PR work.
# So `fixer_defer_sites`/`fixer_defer_shared` are pinned at 0: a gate RE-ADDED to any fixer arm
# reddens this line, and `fixer_sites` still pins the load gate each one carries. The one CI-queue
# defer that survives is the #PR CI RERUN (`! ciq_push_ok`), which genuinely ADDS a run to the queue;
# it is not a fixer spawn and is pinned both here and by ci-queue.test.sh's wiring arms.
fixer_defer_sites=$(grep -cF 'if ciq_push_ok; then' "$LOOP")
fixer_defer_shared=$(grep -cF '] && ciq_push_ok; then' "$LOOP")
rerun_gate=$(grep -cF '! ciq_push_ok' "$LOOP")
fixer_sites=$(grep -F 'wt_count fix-)"' "$LOOP" | grep -cF can_spawn)
# ⛔ AND THE REVIEW ORDER IS ITS OWN SPAWN SITE (agent-infra#2971). The re-record arm used to spawn
# under the `merge-<PR>` tag and compare against `wt_count merge-)`; it now dispatches `review-<PR>`
# and compares against `wt_count review- merge-)` (one review-lane budget across both tag families,
# the semantics the ceiling always had). Without this the literal pattern above would stop seeing the
# site — the count would read 1 and this check would be pinning half of what it names.
merge_site=$(grep -E 'wt_count (review- )?merge-\)"' "$LOOP" | grep -cF can_spawn)
review_site=$(grep -cF '&& can_spawn \' "$LOOP")
[ "$fixer_sites" = "3" ] && rc=0 || rc=1
ck "all three fixer spawn sites (conflict + CI-red + red-fixer) carry the load gate" $rc
[ "$fixer_defer_sites" = "0" ] && rc=0 || rc=1
ck "NO fixer spawn arm is CI-queue-gated (#2927 — a fixer is REPAIR; found $fixer_defer_sites, expected 0)" $rc
[ "$fixer_defer_shared" = "0" ] && rc=0 || rc=1
ck "…and the review-gate fixer's eligibility no longer shares a queue gate either (found $fixer_defer_shared, expected 0)" $rc
[ "$rerun_gate" = "1" ] && rc=0 || rc=1
ck "…while the one act that ADDS a run to the queue — the CI rerun — is still gated (found $rerun_gate, expected 1)" $rc
[ "$merge_site" = "2" ] && rc=0 || rc=1
ck "both merge spawn sites (the review order review-<PR> + rail-mode GREEN merge-<PR>) carry the load gate" $rc
[ "$review_site" = "1" ] && rc=0 || rc=1
ck "the review-fix spawn carries the load gate" $rc
grep -q 'gh pr merge "\$PR" --repo "\$OR" --squash >>"\$LOG"' "$LOOP" && rc=0 || rc=1
ck "the cheap merge path stays ungated" $rc

# ── refresh-candidates.sh: the pool is ordered by SEVERITY, not by issue number ─────
# #8465: the pool was sorted `sort -n -u` over the NUMBERS ALONE — oldest first — so 238
# pool-eligible P2-moderate sat ahead of 20 P0-blocker and the P0s were unreachable. Extract the
# REAL pipeline from the shipped script and drive it with a fixture; re-implementing the sort here
# would pass on the broken copy too. Verified non-vacuous: the pre-fix extraction yields `sort -n -u`,
# whose output is `0 7951 1 8039 2 1120` and fails this assertion.
POOL_SORT="$(grep -E '^\} \| sort ' "$REFRESH" | sed -e 's/^} | //' -e 's/ > "\$O\/\.pool"$//')"
if [ -n "$POOL_SORT" ]; then
  # The within-tier pairs are MIXED WIDTH on purpose. With every number four digits, `sort -n`
  # happens to agree with `sort -k1,1n -k2,2n` on this fixture, so a copy that dropped the key spec
  # stayed green (verified 2026-10-13). 900/1000 separate them — keyed puts 900 first, a bare
  # `sort -n` puts 1000 first — and tortoise is about to cross issue 10000.
  pool_got="$(printf '2 1120\n1 8039\n0 7951\n2 3147\n1 7936\n0 7846\n2 3329\n1 8039\n0 3846\n1 900\n1 1000\n' \
              | sh -c "$POOL_SORT" | tr '\n' ' ' | sed 's/ *$//')"
  [ "$pool_got" = "3846 7846 7951 900 1000 7936 8039 1120 3147 3329" ] && rc=0 || rc=1
else rc=1; fi
ck "refresh-candidates.sh orders the pool severity-first (P0<P1<P2), age second, dedup by number" $rc

# The pipeline above cannot see the TIER->RANK half. A copy that emitted the SAME rank for every
# tier still sorts "correctly" and still starves the P0s — #8465 itself. So assert the label->rank
# pairs the shipped script actually emits. Join backslash continuations first, or `--label` and the
# `|"N ` land on different lines and the extraction finds nothing (verified).
if [ -s "$REFRESH" ]; then
  RANKS="$(awk '{printf "%s", $0} /\\$/{next} {print ""}' "$REFRESH" \
    | awk '/--label/{lab=""; for(i=1;i<=NF;i++) if($i=="--label") lab=$(i+1);
	     if(match($0,/\|"[0-9] /)) print lab" -> "substr($0,RSTART+2,1)}' \
    | tr '\n' ' ' | sed 's/ *$//')"
  [ "$RANKS" = "P0-blocker -> 0 P1-severe -> 1 P2-moderate -> 2" ] && rc=0 || rc=1
else rc=1; fi
ck "refresh-candidates.sh ranks the tiers P0=0 < P1=1 < P2=2 (a constant rank would starve the P0s)" $rc

# The backlog is consumed top-down, so its ORDER IS the priority — a numeric re-sort put the P0s
# behind the P2s on every cycle (#8465). Assert BEHAVIOUR, not spelling: drive the shipped TAIL —
# the dedupe line to EOF, with the real $O redirected into $TMP — against a fixture, and assert the
# resulting file. Executing it is what makes the check spelling-independent. The textual forms both
# missed and over-matched: a grep for a command-position `sort` accepted 10 of 16 built variants that
# really did re-sort the backlog (`LC_ALL=C sort`, `command sort`, `env sort`, a subshell, an `if`, an
# absolute path, the path in a variable…), and it went RED on a COMMENT that merely quoted the pre-fix
# line — the natural thing to write here. A comment is inert when executed; it cannot trip this.
# Driving the dedupe line ALONE is also not enough: that cannot see an ADDED re-sort after it, so this
# drives to EOF rather than `-m1`.
# ⛔ ANCHOR BELOW THE POOL LOOP, NOT AT THE DEDUPE LINE. The pre-fix re-sort sat directly after
# `done < "$O/.pool"`, so anchoring on the dedupe left its own former position — the most likely
# place a partial revert restores it — outside the driven region: with the pre-fix line re-added
# there this check reported 130 passed, 0 failed (reproduced 2026-10-13 against the head). Starting
# after the loop's `done` covers every write the pool loop and the dedupe make to candidates.txt.
# RESIDUAL — a boundary, not a claim of completeness: the driven region starts after the pool loop,
# so code ABOVE it is not executed. The pool pipeline writes `$O/.pool`, never candidates.txt, and the
# reaping pass above that writes dispatched.txt/checked.txt — so nothing above the loop can re-sort the
# backlog today. A re-sort GATED on a value assigned above the loop would still be missed (verified).
# Widening further means stubbing `gh` and driving the pool build too; this is the boundary drawn.
if [ -s "$REFRESH" ]; then
  awk '/^done < /{f=1;next} f' "$REFRESH" > "$TMP/tail.sh"
  # Fail closed if the extraction found nothing, or lost the file it is supposed to exercise.
  if [ -s "$TMP/tail.sh" ] && grep -q 'candidates\.txt' "$TMP/tail.sh"; then
    # Redirect $O at the SOURCE rather than editing paths: `awk -v` passes the fixture dir without any
    # shell quoting of `$O` on the command line. Escape it first — in awk's gsub REPLACEMENT `&` means
    # the matched text and `\x` is an escape, so a `&` or `\\` in $TMP would corrupt the generated
    # script. macOS `mktemp -d` ignores TMPDIR so it cannot occur here, but the Linux CI lane honours
    # TMPDIR and this harness treats `&`-in-path as hostile everywhere else.
    esc_tmp="${TMP//\\/\\\\}"; esc_tmp="${esc_tmp//&/\\&}"
    awk -v tmp="$esc_tmp" '{gsub(/\$O/, tmp)} 1' "$TMP/tail.sh" > "$TMP/tail-drive.sh"
    # 5000 leads AND repeats, so one expectation separates all three outcomes: in-place dedupe keeps
    # the first occurrence (5000 100 9000); a re-sort of ANY spelling moves 100 to the front; a
    # deleted dedupe leaves both 5000s.
    printf '5000\n100\n9000\n5000\n' > "$TMP/candidates.txt"
    # ⛔ SANDBOX THE DRIVE. The substitution above only rewrites the literal `$O`; a path spelled any
    # other way escapes to the REAL location — and `$HOME/orchestrator/candidates.txt` is the shipped
    # script's own default O and is live on a running box. Binding O and HOME to $TMP closes it
    # (confirmed: without this a `$HOME/orchestrator/...` variant rewrote the live file).
    ( cd "$TMP" && O="$TMP" HOME="$TMP" bash tail-drive.sh ) >/dev/null 2>&1
    tail_got="$(tr '\n' ' ' < "$TMP/candidates.txt" 2>/dev/null | sed 's/ *$//')"
    [ "$tail_got" = "5000 100 9000" ] && rc=0 || rc=1
  else rc=1; fi
else rc=1; fi
ck "refresh-candidates.sh dedupes the backlog in place and nothing running it re-sorts it" $rc

# ── 19) the harness runs on Linux as well as macOS (#1702) ──────────────────────
# The shipped cell controller (cloud-cell-supervisor.sh) starts THIS loop on a Linux cell, and every
# capacity probe it used was macOS-only. Reproduced on GNU coreutils 9.7 (debian:stable-slim):
# `stat -f '%m' F` prints the FILESYSTEM LISTING on stdout and exits 1, so the `|| echo` fallback
# APPENDED, the arithmetic failed, `age` was never assigned, and set -u turned the following test
# into `age: unbound variable` — the controller died one cycle after its first dispatch, on every
# cell. The Linux branch of each replacement is driven below, with the GNU shapes stubbed.
# Verified the hard way: dropped into the PRE-FIX tree, these checks FAIL (reproduced against the
# pre-fix orch-loop.sh: file_mtime_epoch extraction empty and the GNU-shape reaper drive aborts).
# Called for by the issue's own verification table: a stub `stat` that reproduces the GNU shapes. It
# is created UNCONDITIONALLY so the reaper drive below really is driven by GNU semantics even when
# the helper is absent (otherwise the stub would be missing, the real BSD stat would answer, and the
# drive would pass on the broken copy — verified by running it against the pre-fix tree).
mkdir -p "$TMP/gnubin"
cat > "$TMP/gnubin/stat" <<'SH'
#!/bin/bash
# GNU coreutils shape, emulated on ANY host:
#   -c '%Y' <file>  -> succeeds, printing the epoch (real GNU behaviour)
#   -f '%m' <file>  -> prints the FILESYSTEM LISTING on stdout and exits 1 (real GNU behaviour)
# The -c branch MUST NOT delegate to the ambient /usr/bin/stat. Doing so emulates "GNU success" with
# a BSD binary on a mac and with a GNU one on Linux — either way the drive tests the HOST, not the
# GNU shape, and on Linux the branch returned GNU's listing/failure so the reaper skipped every
# session and the drive below reaped nothing (the four §19 checks false-redded the fixed tree).
# `date -r <file> +%s` is the portable way to ask any host for a file's epoch mtime.
if [ "${1:-}" = "-c" ]; then date -r "${3:-}" +%s; exit $?; fi
if [ "${1:-}" = "-f" ]; then echo "/dev/disk1 234881024 1234 5678 9% /"; exit 1; fi
exit 1
SH
chmod +x "$TMP/gnubin/stat"
sed -n '/^file_mtime_epoch() {/,/^}/p' "$LOOP" > "$TMP/mtime-body.sh"
# `need` on the helper ALONE: if it is absent (the pre-fix tree) the whole block is skipped, rather
# than every check inside passing vacuously off `command not found` (which really does return rc!=0).
if need "$TMP/mtime-body.sh" "file_mtime_epoch() is extracted from the shipped loop"; then
  { grep -m1 '^is_num() {' "$LOOP"; cat "$TMP/mtime-body.sh"; } > "$TMP/mtime.sh"
  : > "$TMP/mt.log"; touch -t 202601010000 "$TMP/mt.log"
  # The expected epoch is the FILE's, asked of the host portably. `/usr/bin/stat -f '%m'` is BSD-only:
  # on GNU coreutils it prints the filesystem listing to stdout and exits 1, so `want` became a
  # listing and the comparisons below failed against a CORRECT helper. `date -r <file> +%s` works on
  # both (GNU and BSD date accept a reference file), so this check no longer assumes the host's shape.
  want="$(date -r "$TMP/mt.log" +%s)"
  got="$(bash -c ". '$TMP/mtime.sh'; file_mtime_epoch '$TMP/mt.log'")"
  [ "$got" = "$want" ] && rc=0 || { rc=1; echo "      host got '$got' want '$want'"; }
  ck "file_mtime_epoch(): the host's real stat path returns the file's epoch mtime" $rc
  got="$(PATH="$TMP/gnubin:$PATH" bash -c ". '$TMP/mtime.sh'; file_mtime_epoch '$TMP/mt.log'")"
  [ "$got" = "$want" ] && rc=0 || { rc=1; echo "      gnu got '$(printf '%s' "$got" | tr '\n' '|')'"; }
  ck "file_mtime_epoch(): the GNU shape (stat -f prints a listing) still yields ONE numeric epoch" $rc
  # Both shapes fail -> non-zero rc with NO guessed age. The reaper then SKIPS the session; it must
  # not fall back to `date +%s` (age 0 is a guess that reads as a healthy worker either way).
  got="$(PATH="$TMP/gnubin:$PATH" bash -c ". '$TMP/mtime.sh'; file_mtime_epoch '$TMP/absent.log' && echo ZERO || echo NONZERO")"
  [ "$got" = "NONZERO" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "file_mtime_epoch(): an unreadable file fails to a non-zero rc instead of guessing an age" $rc
fi
# The reaper driven with the GNU stat shape: the pre-fix copy ABORTS here (`age: unbound variable`,
# rc 1) and kills nothing. Assert rc=0 AND the kill decision — stale reaped, fresh spared — so a
# "fix" that simply stopped reaping cannot pass this.
{ grep -m1 '^is_num() {' "$LOOP"; sed -n '/^file_mtime_epoch() {/,/^}/p' "$LOOP"; sed -n '/^reap_stale_workers() {/,/^}/p' "$LOOP"; } > "$TMP/reapw-gnu.sh"
if need "$TMP/reapw-gnu.sh" "the reaper and its stat helper are extracted for the GNU-shape drive"; then
  mkdir -p "$TMP/RG/logs" "$TMP/RG/state"
  : > "$TMP/RG/logs/merge-999.log"; touch -t 202601010000 "$TMP/RG/logs/merge-999.log"
  : > "$TMP/RG/logs/merge-100.log"
  # The census needs python3 for its one daemon read, and this driver runs with a REDUCED PATH (the
  # GNU stat stub first) — so the stub dir carries a python3 link instead of the driver widening PATH.
  ln -sf "$(command -v python3)" "$TMP/gnubin/python3" 2>/dev/null || true
  cat > "$TMP/rg.sh" <<SH
set -u
PATH="$TMP/gnubin:\$PATH"
LOG="$TMP/RG/rw.log"; O="$TMP/RG"; WT_DIR="$TMP/RG/state"; STALE_MIN=1; WT_TABLE_TTL=0
. "$TMP/wtstub.sh"
printf 'kind=terminal\nid=term_merge-999\nworkspace=ws_merge-999\n' > "$TMP/RG/state/worker-merge-999"
printf 'kind=terminal\nid=term_merge-100\nworkspace=ws_merge-100\n' > "$TMP/RG/state/worker-merge-100"
. "$HERE/worker-terminal.sh"
. "$TMP/reapw-gnu.sh"
reap_stale_workers; rc=\$?
echo "rc=\$rc closed=\$CLOSED"
SH
  out="$(bash "$TMP/rg.sh" 2>&1)"
  case "$out" in *"rc=0"*) rc=0;; *) rc=1; echo "      got: $out";; esac
  ck "shipped reaper, GNU stat shape: the cycle COMPLETES (rc 0) with no arithmetic abort" $rc
  case "$out" in *"merge-999"*) rc=0;; *) rc=1;; esac
  ck "shipped reaper, GNU stat shape: the stale worker is reaped" $rc
  # ⛔ NOT a bare "does not contain merge-100": that is trivially true when the reaper ABORTS, so it
  # PASSED on the pre-fix code (verified against origin/main's orch-loop.sh). Assert the POSITIVE in
  # the same check — the run completed (rc 0) AND the closed set is EXACTLY the stale worker — so a
  # crash and an over-reaching reaper both fail here. The stub records the terminal id it was asked
  # to close, so the comparison is exact rather than a substring match that a second id would satisfy.
  case "$out" in *"rc=0"*) rc=0;; *) rc=1; echo "      not rc=0: $out";; esac
  closed_list="$(printf '%s\n' "$out" | grep -o 'closed=.*' | sed 's/^closed= *//')"
  [ "$closed_list" = "term_merge-999" ] || { rc=1; echo "      closed exactly: '$closed_list'"; }
  ck "shipped reaper, GNU stat shape: completes (rc 0) and reaps exactly the stale worker" $rc
  grep -q 'reap-worker' "$TMP/RG/rw.log" 2>/dev/null && rc=0 || rc=1
  ck "shipped reaper, GNU stat shape: the kill is logged" $rc
fi
sed -n '/^load1() {/,/^}/p' "$LOOP" > "$TMP/load1.sh"
if need "$TMP/load1.sh" "load1() is extracted from the shipped loop"; then
  printf '7.42 1.10 0.95 2/345 999\n' > "$TMP/loadavg"
  got="$(bash -c ". '$TMP/load1.sh'; load1 '$TMP/loadavg'")"
  [ "$got" = "7" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "shipped load1(): the Linux (/proc/loadavg) path reads FIELD 1 as the 1-min load" $rc
  # macOS prints '{ 1.70 1.90 2.00 }', so there the 1-min load is field 2. Pin the FIELD, not only
  # the path: one awk shared by both platforms would pass a path-only check and still read 5-min.
  got="$(bash -c "sysctl() { echo '{ 3.30 4.40 5.50 }'; }; . '$TMP/load1.sh'; load1 '$TMP/absent-loadavg'")"
  [ "$got" = "3" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "shipped load1(): the macOS (sysctl vm.loadavg) path reads the 1-min field, not the 5-min" $rc
fi
sed -n '/^swap_usage_mb() {/,/^}/p' "$LOOP" > "$TMP/swap.sh"
if need "$TMP/swap.sh" "swap_usage_mb() is extracted from the shipped loop"; then
  printf 'MemTotal:       16000000 kB\nSwapTotal:       2048000 kB\nSwapFree:        1024000 kB\n' > "$TMP/meminfo"
  got="$(bash -c ". '$TMP/swap.sh'; swap_usage_mb '$TMP/meminfo'")"
  [ "$got" = "1000 2000" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "shipped swap_usage_mb(): the Linux (/proc/meminfo) path converts kB to MB as <free> <total>" $rc
  # 'we could not read it' must stay distinguishable from 'no swap configured' (total 0, the allow).
  # BOTH probes are stubbed to fail: with only the meminfo path unavailable the function correctly
  # falls back to sysctl, which is not the state under test here.
  got="$(bash -c "sysctl() { :; }; . '$TMP/swap.sh'; swap_usage_mb '$TMP/absent-meminfo' && echo OK || echo NONZERO")"
  [ "$got" = "NONZERO" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "shipped swap_usage_mb(): an unreadable probe returns non-zero, not a false '0 0'" $rc
  got="$(bash -c "sysctl() { echo 'total = 2048.00M  used = 1.00M  free = 2047.00M'; }; . '$TMP/swap.sh'; swap_usage_mb '$TMP/absent-meminfo'")"
  [ "$got" = "2047 2048" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "shipped swap_usage_mb(): the macOS (sysctl vm.swapusage) path still yields <free> <total> MB" $rc
fi
# Available memory is the FIFTH macOS-only probe and the only one that fails CLOSED: before #1702 a
# cell reported no vm_stat, so MEM_UNKNOWN was set every cycle and `mem_probe_failed` bound the gate
# FOREVER when load/lanes/swap were healthy — the controller ran, logged, and never dispatched a
# lane. That is the false green #1702 removes, so the Linux path is driven explicitly here.
sed -n '/^mem_avail_mb() {/,/^}/p' "$LOOP" > "$TMP/mem.sh"
if need "$TMP/mem.sh" "mem_avail_mb() is extracted from the shipped loop"; then
  { grep -m1 '^is_num() {' "$LOOP"; cat "$TMP/mem.sh"; } > "$TMP/memfull.sh"
  # MemAvailable 6144000 kB = 6000 MB; MemFree+Cached = 2048000+4096000 = 6144000 kB too, so one
  # expectation separates "read MemAvailable" from "read MemFree+Cached".
  printf 'MemTotal:       16000000 kB\nMemFree:         2048000 kB\nCached:          4096000 kB\nMemAvailable:    6144000 kB\n' > "$TMP/meminfo2"
  got="$(bash -c ". '$TMP/memfull.sh'; mem_avail_mb '$TMP/meminfo2'")"
  [ "$got" = "6000" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "shipped mem_avail_mb(): the Linux (/proc/meminfo MemAvailable) path yields available MB" $rc
  # Pre-3.14 kernels have no MemAvailable; MemFree+Cached is the documented fallback.
  printf 'MemTotal:       16000000 kB\nMemFree:         2048000 kB\nCached:          4096000 kB\n' > "$TMP/meminfo3"
  got="$(bash -c ". '$TMP/memfull.sh'; mem_avail_mb '$TMP/meminfo3'")"
  [ "$got" = "6000" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "shipped mem_avail_mb(): falls back to MemFree+Cached when MemAvailable is absent" $rc
  # macOS path kept: (1000 free + 2000 inactive) * 16384 B / 1 MiB = 46 (truncated).
  got="$(bash -c "vm_stat() { printf 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\\nPages free: 1000.\\nPages inactive: 2000.\\n'; }; . '$TMP/memfull.sh'; mem_avail_mb '$TMP/absent-meminfo'")"
  [ "$got" = "46" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "shipped mem_avail_mb(): the macOS (vm_stat free+inactive) path still yields available MB" $rc
  # UNKNOWN must stay distinguishable from "0 MB available": the gate fails CLOSED on the former.
  got="$(bash -c "vm_stat() { :; }; . '$TMP/memfull.sh'; mem_avail_mb '$TMP/absent-meminfo' && echo OK || echo NONZERO")"
  [ "$got" = "NONZERO" ] && rc=0 || { rc=1; echo "      got '$got'"; }
  ck "shipped mem_avail_mb(): an unreadable probe returns non-zero (UNKNOWN), not a false 0" $rc
fi
# The regression guard that does not depend on any single spelling of the call site: a macOS-only
# kernel probe anywhere OUTSIDE the portable helpers is the bug, still shipped. `vm_stat` is included
# because it is the probe whose Linux absence was the LAST false green (the guard previously scoped
# only load/swap/mtime and so could not see it). `res_line` is exempt: it is a log-only measurement
# (`res_line` is called under "MEASURE every resource; decide nothing from it"), its memory field
# degrades to `?` off macOS, and it cannot gate dispatch — the gate's available-memory figure is
# mem_avail_mb(), whose call site is asserted separately below.
outside="$(awk '
  /^[[:space:]]*#/ {next}
  /^file_mtime_epoch\(\) \{|^load1\(\) \{|^swap_usage_mb\(\) \{|^mem_avail_mb\(\) \{|^res_line\(\) \{/ {h=1}
  h && /^\}/ {h=0; next}
  h {next}
  /sysctl -n (vm\.loadavg|vm\.swapusage)|stat -f .%m.|vm_stat/ {print FNR": "$0}
' "$LOOP")"
[ -z "$outside" ] && rc=0 || { rc=1; echo "      outside the helpers: $outside"; }
ck "no call site uses a macOS-only load/swap/mtime/memory probe outside the portable helpers" $rc
grep -q 'if _sw="$(swap_usage_mb)"; then SWFREE=' "$LOOP" && rc=0 || rc=1
ck "the dispatch gate reads swap through swap_usage_mb()" $rc
grep -q 'if MEMAVAIL_MB="$(mem_avail_mb)"; then' "$LOOP" && rc=0 || rc=1
ck "the dispatch gate reads available memory through mem_avail_mb() (not a bare vm_stat)" $rc
grep -q 'm="$(file_mtime_epoch "$f")" || continue' "$LOOP" && rc=0 || rc=1
ck "the reaper reads the log mtime through file_mtime_epoch() and skips on unknown" $rc
# install.sh renders MAX_LOAD into the plist from its OWN _NCPU and section 7 compares the two
# files' effective defaults — a divergence there would only surface ON a Linux host, so pin it here.
grep -q 'nproc 2>/dev/null' "$INST" && rc=0 || rc=1
ck "install.sh derives _NCPU portably too (its MAX_LOAD must match the loop's on any host)" $rc
# ⛔ AND install.sh MUST CARRY THE SAME GUARD (P3, third review round, 2026-10-14). orch-loop.sh
# coerces `_NCPU` on the line above its only read; install.sh had NO is_num at all, so a `sysctl`
# that SUCCEEDS while printing garbage (or empty) made `$(( 10#$_NCPU * 10 ))` a syntax error that
# ABORTS the installer mid-run under `set -euo pipefail` — instead of falling back to 4 as the loop
# does. Extract the shipped lines and DRIVE them with a sysctl stub: a missing guard is a hard
# failure, not a cosmetic difference from the loop. Red on the pre-fix install.sh.
# ⛔ AND THE EXTRACTION MUST TAKE THE WHOLE GUARD (P3, fifth review round, 2026-10-14). The pattern
# used to name `is_num("${_NCPU` explicitly; install.sh now uses `is_limit` (the magnitude bound)
# plus the `_NCPU >= 1` probe guard, so an extraction that still named the old lines would miss the
# newly added ones and drive an incomplete block. It is a RANGE: from the predicate definitions
# through the last MAX_LOAD guard, so any guard added inside it is picked up automatically.
sed -n '/^_NCPU=/,/^is_limit "${MAX_LOAD:-}"/p' "$INST" > "$TMP/ncpu-inst.sh"
if need "$TMP/ncpu-inst.sh" "install.sh's _NCPU + MAX_LOAD lines are extracted"; then
  { echo 'set -euo pipefail'; echo 'sysctl() { echo garbage; }'; cat "$TMP/ncpu-inst.sh"; printf 'printf "%%s" "$MAX_LOAD"'; } > "$TMP/ncpu-drive.sh"
  _nout="$(bash "$TMP/ncpu-drive.sh" 2>&1)"; _nrc=$?
  [ "$_nrc" -eq 0 ] && [ "$_nout" = "40" ] && rc=0 || { rc=1; echo "      install.sh _NCPU guard -> rc=$_nrc out='$_nout'"; }
  ck "install.sh falls back to 4 cores when sysctl succeeds but prints garbage (no arithmetic abort)" $rc
  # Non-vacuity: the stub really is the value being consulted, and a good one is still honoured.
  { echo 'set -euo pipefail'; echo 'sysctl() { echo 12; }'; cat "$TMP/ncpu-inst.sh"; printf 'printf "%%s" "$MAX_LOAD"'; } > "$TMP/ncpu-drive2.sh"
  _nout2="$(bash "$TMP/ncpu-drive2.sh" 2>&1)"
  [ "$_nout2" = "120" ] && rc=0 || { rc=1; echo "      a GOOD sysctl=12 gave '$_nout2', expected 120"; }
  ck "install.sh still derives MAX_LOAD from a good _NCPU (12 cores -> 120)" $rc
  # ⛔ THE PRODUCTION PATH'S OWN WRAP (P3, fifth review round, 2026-10-14). install.sh substitutes
  # __MAX_LOAD__ into the LIVE plist, so an absurd-but-numeric `_NCPU` here — not in the loop — was
  # the one that actually wrote `MAX_LOAD=0` into a running box. 2**63 * 10 wraps to exactly 0 and
  # every guard accepts 0, so this is RED on the pre-fix install.sh (which had is_num only).
  { echo 'set -euo pipefail'; echo 'sysctl() { echo 9223372036854775808; }'; cat "$TMP/ncpu-inst.sh"; printf 'printf "%%s" "$MAX_LOAD"'; } > "$TMP/ncpu-drive3.sh"
  _nout3="$(bash "$TMP/ncpu-drive3.sh" 2>&1)"
  [ "$_nout3" = "40" ] && rc=0 || { rc=1; echo "      install.sh _NCPU=2**63 -> plist MAX_LOAD='$_nout3', expected 40 (not 0)"; }
  ck "install.sh bounds an absurd _NCPU so the plist cannot get MAX_LOAD=0 (would dispatch nothing)" $rc
  # A 0-valued probe is a failed probe: the same guard as the loop's.
  { echo 'set -euo pipefail'; echo 'sysctl() { echo 0; }'; cat "$TMP/ncpu-inst.sh"; printf 'printf "%%s" "$MAX_LOAD"'; } > "$TMP/ncpu-drive4.sh"
  _nout4="$(bash "$TMP/ncpu-drive4.sh" 2>&1)"
  [ "$_nout4" = "40" ] && rc=0 || { rc=1; echo "      install.sh _NCPU=0 -> plist MAX_LOAD='$_nout4', expected 40 (not 0)"; }
  ck "install.sh treats a 0-valued _NCPU probe as a failed probe (MAX_LOAD=40, not 0)" $rc
  # The other wrap a MAX_LOAD-only guard cannot see: a 9-digit probe is IN range, but its product is
  # 10 digits and never binds. Only the true-default fallback catches it.
  { echo 'set -euo pipefail'; echo 'sysctl() { echo 999999999; }'; cat "$TMP/ncpu-inst.sh"; printf 'printf "%%s" "$MAX_LOAD"'; } > "$TMP/ncpu-drive5.sh"
  _nout5="$(bash "$TMP/ncpu-drive5.sh" 2>&1)"
  [ "$_nout5" = "40" ] && rc=0 || { rc=1; echo "      install.sh _NCPU=999999999 -> plist MAX_LOAD='$_nout5', expected 40"; }
  ck "install.sh falls back to 40 for a product that outgrows the 9-digit bound" $rc
  # ⛔ A DELIBERATE plist MAX_LOAD=0 MUST STILL BE ACCEPTED (keep the `0) : ;;` arm): the loop's
  # second guard bounds the DERIVATION, never a value that passes is_limit. Non-vacuity for the fix.
  { echo 'set -euo pipefail'; echo 'sysctl() { echo 12; }'; cat "$TMP/ncpu-inst.sh"; printf 'printf "%%s" "$MAX_LOAD"'; } > "$TMP/ncpu-drive6.sh"
  _nout6="$(MAX_LOAD=0 bash "$TMP/ncpu-drive6.sh" 2>&1)"
  [ "$_nout6" = "0" ] && rc=0 || { rc=1; echo "      a deliberate MAX_LOAD=0 became '$_nout6', expected 0"; }
  ck "install.sh still accepts a deliberate plist MAX_LOAD=0 (only the derivation is bounded)" $rc
fi
# ⛔ ORDER, not presence: the `_NCPU` coercion was added in the input-validation block, ~30 lines
# AFTER `MAX_LOAD="${MAX_LOAD:-$(( _NCPU * 10 ))}"` — its only read. A guard that runs after the
# arithmetic cannot protect it ("dead-guard"), so the property to pin is that the coercion line
# PRECEDES the MAX_LOAD line. Both are asserted line-ordered; the check fails on the pre-fix file.
_ncpu_guard_line="$(grep -n 'is_limit "${_NCPU:-}"' "$LOOP" | head -1 | cut -d: -f1)"
_maxload_line="$(grep -n '^MAX_LOAD="' "$LOOP" | head -1 | cut -d: -f1)"
[ -n "$_ncpu_guard_line" ] && [ -n "$_maxload_line" ] && [ "$_ncpu_guard_line" -lt "$_maxload_line" ] && rc=0 || rc=1
ck "orch-loop.sh coerces _NCPU BEFORE MAX_LOAD reads it (guard is not guard-after-use)" $rc
grep -q 'is_limit "${MAX_LOAD:-}"' "$LOOP" && rc=0 || rc=1
ck "orch-loop.sh coerces a non-numeric MAX_LOAD instead of letting the load gate fail OPEN" $rc
# ⛔ Behaviour, not source text. The grep above restates the implementation line, and every other
# fixture in this file sets MAX_LOAD to a valid integer, so nothing ever DROVE the coercion. Extract
# the shipped coercion lines and run them, the way the memory and swap gates are driven above.
# ⛔ THE CYC FLOOR IS MATCHED ON AN ANCHORED CODE LINE, not by substring (P3, fourth review round,
# 2026-10-14). `grep -F '[ "$CYC" -ge 5 ] || CYC=240'` also matched the COMMENTED-OUT line
# (`# [ "$CYC" -ge 5 ] || CYC=240`), so commenting the floor out still satisfied the extraction —
# the guard could not fail while the comment text survived. The `^` is an ANCHOR here, which `-F`
# would have taken literally (verified: `grep -F '^x'` matches nothing), so this is an anchored
# BRE. The behavioural assertion below is the real gate; this only makes the extraction honest.
NGRD="$( { grep -F 'is_num() {' "$LOOP"; grep -F 'is_limit() {' "$LOOP"; grep -E '^is_(num|limit) "\$\{[A-Z_]+:' "$LOOP"; grep '^\[ "\$CYC" -ge 5 \] || CYC=240' "$LOOP"; } )"
# ⛔ Non-vacuity: NGRD ALWAYS contains the is_num() definition, so `[ -n "$NGRD" ]` passes with zero
# coercion lines present -- the guard could not fail while is_num() existed. Count the coercion lines,
# and count an EXACT number: adding a coercion without adding its pin is the failure this catches.
_ngrd_n="$(printf '%s\n' "$NGRD" | grep -cE '^is_(num|limit) "\$\{[A-Z_]+:')"
# 12 -> 14 for agent-infra#1762 (SWEEP_MAX_AGE, SWEEP_MIN_REMAIN); 14 -> 16 for agent-infra#2040
# (MERGE_PRIORITY_MAX_AGE_MIN + FUNNEL_MAX_AGE_MIN: the merge-priority bound and the funnel's age
# bound). The exact count is the point:
# a coercion added without its pin must redden this check, not pass as "more is better".
# 16 -> 18 for agent-infra#2223 (MAX_RED_FIX + MAX_RED_FIX_TRIES: the red-fixer role's box cap and
# its per-head cap — both feed `[ … -ge ]` at a spawn decision, so both fail OPEN uncoerced).
# 18 -> 19 for agent-infra#2653 (MAX_REVIEW_TRIES: the controller now keys its own review dispatches
# on merge-one.sh's per-head review budget, so the SAME limit feeds a `-ge` in a SECOND file — an
# uncoerced copy there would let a typo run the review budget unbounded, which is the loop the bound
# exists to prevent).
[ "$_ngrd_n" = "19" ] && rcn=0 || { rcn=1; echo "      expected 19 shipped coercions in the extraction, got $_ngrd_n"; }
ck "all 19 shipped limit coercions are extracted (a definition alone is not an extraction)" $rcn
# The CYC FLOOR is part of the same coercion block but is not an is_* line, so it is extracted by an
# explicit pattern (P3, third review round, 2026-10-14). Without it in NGRD, `nlim` could not drive
# CYC=0 and the floor assertion below would be RED on the FIXED file — a false negative that would
# make the fix look broken. Non-vacuity: require the floor line to be present in the extraction, again
# ANCHORED so a commented-out floor cannot satisfy it, and via a here-string (the `printf … | grep -q`
# form is the #841 SIGPIPE false-negative idiom that scripts/check-no-sigpipe-grep.sh rejects).
grep -q '^\[ "\$CYC" -ge 5 \] || CYC=240' <<<"$NGRD" && rcf=0 || { rcf=1; echo "      the CYC floor line is missing from the extraction"; }
ck "the shipped CYC floor is extracted too (CYC=0 cannot be driven without it)" $rcf
# <MAX_LOAD> <MAX_LANES> <MERGE_PRIORITY_AT> <BATCH>, with MAX_REVIEW/MAX_FIX/MAX_FIX_TRIES/STALE_MIN
# unset and CYC non-numeric -> the values the shipped coercion leaves behind
# ⛔ HERMETIC: every variable the coercion block touches is set explicitly. Leaving them unset is not
# enough -- an earlier section sets STALE_MIN=1, the subshell inherits it, is_limit sees a valid value
# and does not coerce, and the assertion then measures the wrong thing while still passing its shape.
nlim() { ( _NCPU=10; MAX_LOAD="$1"; MAX_LANES="$2"; MERGE_PRIORITY_AT="$3"; BATCH="$4"; CYC="${5:-abc}"
           MAX_REVIEW=; MAX_FIX=; MAX_FIX_TRIES=; MAX_RED_FIX=; MAX_RED_FIX_TRIES=; STALE_MIN=; MAX_REVIEW_TRIES=
           eval "$NGRD"; printf 'load=%s lanes=%s mpa=%s batch=%s cyc=%s review=%s fix=%s fixtries=%s revtries=%s stale=%s' "$MAX_LOAD" "$MAX_LANES" "$MERGE_PRIORITY_AT" "$BATCH" "$CYC" "$MAX_REVIEW" "$MAX_FIX" "$MAX_FIX_TRIES" "$MAX_REVIEW_TRIES" "$STALE_MIN" ); }
[ "$(nlim abc abc notanum two)" = "load=100 lanes=25 mpa=25 batch=2 cyc=240 review=4 fix=3 fixtries=3 revtries=3 stale=40" ] && rc=0 || { rc=1; echo "      got '$(nlim abc abc notanum two)'"; }
ck "non-numeric plist limits are coerced to their defaults, not left to fail OPEN" $rc
# ⛔ AND MAX_LANES IS REPAIRED TO ITS DERIVED DEFAULT, NOT TO A FLAT NUMBER (owner ruling, 2026-10-17):
# the driver pins `_NCPU=10`, so a garbage lane ceiling must come back as 25 — the value the box's
# CORES imply — not the 4 it used to be repaired to. Reverting the coercion to `|| MAX_LANES=4`
# reddens the two cases above and below.
[ "$(nlim 30 6 20 5)" = "load=30 lanes=6 mpa=20 batch=5 cyc=240 review=4 fix=3 fixtries=3 revtries=3 stale=40" ] && rc=0 || rc=1
ck "numeric plist limits survive the coercion unchanged" $rc
# ⛔ A 2**63-shaped value is the SECOND failure mode, and is_num alone cannot see it: `[ -ge ]` on it
# prints "integer expression expected" and exits 2, which under `set -e` aborts the gate chain -- or,
# read as false, OPENS it. `is_limit` bounds the digits, so this must coerce exactly as a typo does.
# Review found MAX_LOAD was still is_num while the README claimed otherwise: this is that gap, driven.
[ "$(nlim 99999999999999999999 6 20 5)" = "load=100 lanes=6 mpa=20 batch=5 cyc=240 review=4 fix=3 fixtries=3 revtries=3 stale=40" ] && rc=0 || { rc=1; echo "      got '$(nlim 99999999999999999999 6 20 5)'"; }
ck "an absurd-but-numeric MAX_LOAD (>= 2**63) is coerced, not left to error the gate chain" $rc
# ⛔ THE DERIVATION, not just the coercion (P3, fourth review round, 2026-10-14). Every fixture above
# passes MAX_LOAD EXPLICITLY, so nothing drove the fallback `is_limit … || MAX_LOAD=$(( 10#$_NCPU * 10 ))`
# — which re-derived from the SAME unbounded `_NCPU` and could therefore leave an out-of-range value
# in place. Extract the shipped `_NCPU` guard + derivation + coercion and DRIVE it with an absurd
# probe, whose magnitude WRAPS (it does not abort), so the range guard cannot see it downstream.
# The block always carries the two is_* DEFINITIONS, so a non-empty extraction proves nothing; the
# `a sane _NCPU still derives MAX_LOAD=cores*10` assertion below IS the non-vacuity guard (it can
# only pass if the derivation line was evaluated).
{ grep -F 'is_num() {' "$LOOP"; grep -F 'is_limit() {' "$LOOP"; sed -n '/^is_limit "\${_NCPU:-}"/,/^[[:space:]]*is_limit "\${MAX_LOAD:-}"/p' "$LOOP"; } > "$TMP/maxb.sh"
if need "$TMP/maxb.sh" "the shipped _NCPU guard + MAX_LOAD derivation are extracted"; then
  MAXB="$(cat "$TMP/maxb.sh")"
  maxload_probe() { ( _NCPU="$1"; MAX_LOAD="$2"; eval "$MAXB"; printf '%s' "$MAX_LOAD" ); }
  [ "$(maxload_probe 12 '')" = "120" ] && rc=0 || { rc=1; echo "      _NCPU=12 -> '$(maxload_probe 12 '')', expected 120"; }
  ck "a sane _NCPU still derives MAX_LOAD=cores*10 through the shipped block" $rc
  # A 0-valued probe is a FAILED probe: `10 * 0` = 0 passes is_limit and `[ "$L" -ge 0 ]` is always
  # true, so the load gate closes forever. The `_NCPU >= 1` guard converts it to the default.
  [ "$(maxload_probe 0 '')" = "40" ] && rc=0 || { rc=1; echo "      _NCPU=0 -> '$(maxload_probe 0 '')', expected 40 (not 0)"; }
  ck "a 0-valued _NCPU probe is treated as failed (MAX_LOAD=40, not a gate that never opens)" $rc
  [ "$(maxload_probe 99999999999999999999 '')" = "40" ] && rc=0 || { rc=1; echo "      _NCPU=1e20 -> '$(maxload_probe 99999999999999999999 '')', expected 40"; }
  ck "an absurd _NCPU (>= 2**63) falls back to 40, not a 19-digit load gate that never binds" $rc
  # The other wrap, and the one a MAX_LOAD-only guard CANNOT catch: 2**63 * 10 wraps to 0, and
  # `is_limit 0` is TRUE (install.sh allows 0 for every limit but CYC), so `[ "$L" -ge 0 ]` is always
  # true and the controller dispatches nothing, forever. Only bounding the PROBE closes it.
  [ "$(maxload_probe 9223372036854775808 '')" = "40" ] && rc=0 || { rc=1; echo "      _NCPU=2**63 -> '$(maxload_probe 9223372036854775808 '')', expected 40"; }
  ck "an _NCPU that wraps the product to 0 (which passes is_limit) is bounded to 40" $rc
  # A 9-digit _NCPU is in range, but its product is 10 digits and still under 2**63 — `[ -ge ]` does
  # not error, it just never binds, so ONLY the true-default fallback catches it.
  [ "$(maxload_probe 999999999 '')" = "40" ] && rc=0 || { rc=1; echo "      _NCPU=999999999 -> '$(maxload_probe 999999999 '')', expected 40"; }
  ck "a product that outgrows the 9-digit bound falls back to 40, not a gate that never binds" $rc
  [ "$(maxload_probe 99999999999999999999 30)" = "30" ] && rc=0 || { rc=1; echo "      absurd _NCPU + MAX_LOAD=30 -> '$(maxload_probe 99999999999999999999 30)'"; }
  ck "a valid plist MAX_LOAD survives even an absurd _NCPU (the derivation is bounded, not the value)" $rc
fi
# ⛔ LEADING ZEROS — the third failure mode, and the one the FIRST fix missed (P1/P2, second review
# round, 2026-10-14). `is_num` used `''|*[!0-9]*`, which ACCEPTS `08`; that reached `$(( 08 + … ))`,
# where bash parses base 0 (leading 0 = OCTAL) and `08` is not octal. On /bin/bash 3.2.57 the failed
# arithmetic ASSIGNMENT aborts the rest of the enclosing block and resumes after it with status 0 —
# so `CYC=08` DISCARDED the controller's `while true` loop (exit 0 after one cycle, relaunch-per-cycle
# under KeepAlive) and `REVIEW_TIMEOUT=08` silently skipped claim_acquire. `is_limit` delegates to
# `is_num`, so tightening the predicate coerces every leading-zero limit to its default — this drives
# that, and it is RED on the lax predicate. (`nlim 08 09 030 05` covers 2-digit, 3-digit and the
# single `0`-followed-by-digit forms.)
[ "$(nlim 08 09 030 05)" = "load=100 lanes=25 mpa=25 batch=2 cyc=240 review=4 fix=3 fixtries=3 revtries=3 stale=40" ] && rc=0 || { rc=1; echo "      got '$(nlim 08 09 030 05)'"; }
ck "leading-zero limits (08/09/030/05) are coerced to defaults, not read as octal" $rc
# ⛔ CYC=0 — the FOURTH failure mode, and the one every guard above lets through: `0` is a valid
# integer and a valid is_limit, so it survives the coercion and the loop then runs `sleep 0` per
# cycle, revisiting with no delay and hammering the GitHub API (P3, third review round, 2026-10-14).
# The floor is part of the same block, so this drives it: CYC=0 must come out 240. A mutation that
# drops the floor line leaves cyc=0 here — RED.
[ "$(nlim 30 6 20 5 0)" = "load=30 lanes=6 mpa=20 batch=5 cyc=240 review=4 fix=3 fixtries=3 revtries=3 stale=40" ] && rc=0 || { rc=1; echo "      got '$(nlim 30 6 20 5 0)'"; }
ck "CYC=0 is floored to 240 (a zero-delay cycle re-hits the GitHub API with no delay)" $rc
# Non-vacuity: the floor must not swallow a deliberately SMALL cycle. 5 is allowed and must survive.
[ "$(nlim 30 6 20 5 5)" = "load=30 lanes=6 mpa=20 batch=5 cyc=5 review=4 fix=3 fixtries=3 revtries=3 stale=40" ] && rc=0 || { rc=1; echo "      got '$(nlim 30 6 20 5 5)'"; }
ck "a deliberate small CYC=5 survives the floor unchanged" $rc
# And pin the predicate itself, so the coercion above cannot be satisfied by some unrelated path:
# `is_num 08` must be FALSE, while `0` and a real number stay true.
{ grep -m1 '^is_num() {' "$LOOP"; } > "$TMP/isnum.sh"
_isnum_ok=1
( . "$TMP/isnum.sh"
  is_num 08 && exit 1
  is_num 09 && exit 1
  is_num 030 && exit 1
  is_num 0  || exit 1
  is_num 8  || exit 1
  is_num 1800 || exit 1
  is_num '' && exit 1
  is_num abc && exit 1
  exit 0 ) || _isnum_ok=0
[ "$_isnum_ok" = "1" ] && rc=0 || { rc=1; echo "      the shipped is_num() still accepts a leading-zero or non-number value"; }
ck "the shipped is_num() rejects leading zeros and non-numbers, accepts 0 and real numbers" $rc
# ⛔ MAX_LOAD's DEFAULT -- not its coercion -- decides the value when the plist does not set one, and
# every other fixture passes MAX_LOAD explicitly, so `_NCPU * 10` -> `_NCPU * 5` in BOTH files stayed
# green. Pin the FORMULA, which is host-independent even though its evaluation is not.
# ⛔ rc=0 first: this loop only ever ASSIGNS 1, so without the reset a stale rc from an earlier check
# makes it a false red -- the very "rc set but not asserted" defect this file warns about.
rc=0
for _f in "$LOOP" "$INST"; do
  grep -qF 'MAX_LOAD="${MAX_LOAD:-$(( 10#$_NCPU * 10 ))}"' "$_f" || { rc=1; echo "      $_f does not default MAX_LOAD to cores*10"; }
done
ck "both files default MAX_LOAD to the cores*10 formula (it cannot drift in both together)" $rc
# ⛔ The leading-zero trap, again: MERGE_PRIORITY_AT is normalised with `10#` for the scope decision
# but review_slots read MAX_REVIEW through $(( )) -- `030` returned 26, not 30.
grep -qF '10#${MAX_REVIEW:-4} + 2' "$LOOP" && rc=0 || rc=1
ck "review_slots reads MAX_REVIEW in base 10 (a leading zero is not octal)" $rc
grep -qF '10#${STALE_MIN} * 60' "$LOOP" && rc=0 || rc=1
ck "the reaper reads STALE_MIN in base 10" $rc
if on_darwin; then
# ── install.sh's render guards, DRIVEN (not grepped) ─────────────────────────────
# Source-text pins are exactly what this file was told to stop doing: `if false && grep …` leaves the
# text intact and the guard dead. So RUN the real installer. This is §6's sandbox pattern, seeded with
# an existing plist -- the upgrade path is a re-install over a live config, which is the one a
# non-atomic render destroys.
mk_sb() { local d; d="$(mktemp -d "$TMP/sbx.XXXXXX")"
  mkdir -p "$d/Library/LaunchAgents" "$d/.config" "$d/.pi/agent/scripts" "$d/.local/share/pi-node/current/bin"
  ln -s "$HOME/.config/gh" "$d/.config/gh" 2>/dev/null || true
  [ -f "$HOME/.pi/agent/scripts/record-review.sh" ] && ln -s "$HOME/.pi/agent/scripts/record-review.sh" "$d/.pi/agent/scripts/record-review.sh"
  printf '#!/bin/bash\nexit 0\n' > "$d/.local/share/pi-node/current/bin/pi"; chmod +x "$d/.local/share/pi-node/current/bin/pi"
  printf 'SEED\n' > "$d/Library/LaunchAgents/$TPL"
  printf '%s' "$d"; }
run_inst_at() { # <installer> <sandbox> [VAR=VAL…] -> "<rc>|<live-plist first line>|<stderr tail>"
  local i="$1" d="$2"; shift 2
  env HOME="$d" O="$TMP/glt-o" REPO="$HERE/../.." OR="acme/widget" "$@" bash "$i" >"$d/out" 2>&1
  printf '%s|%s|%s' "$?" "$(head -1 "$d/Library/LaunchAgents/$TPL" 2>/dev/null)" "$(tail -1 "$d/out")"; }
run_inst() { run_inst_at "$INST" "$@"; }
# Fields are "<rc>|<live-plist-first-line>|<stderr tail>" -- slice by FIELD, not by ${out#*|}.
inst_rc()  { printf '%s' "$1" | cut -d'|' -f1; }
inst_pl()  { printf '%s' "$1" | cut -d'|' -f2; }
# A FRESH sandbox per case: a rejected install is not supposed to touch the live plist, but if one
# case (correctly) succeeds it would replace the seed and make every later case meaningless.
out="$(run_inst "$(mk_sb)" MAX_LANES=4x)"
[ "$(inst_rc "$out")" != "0" ] && [ "$(inst_pl "$out")" = "SEED" ] && rc=0 || { rc=1; echo "      MAX_LANES=4x -> '$out'"; }
ck "install.sh refuses a non-integer limit AND leaves the live plist untouched" $rc
out="$(run_inst "$(mk_sb)" MAX_LANES=99999999999999999999)"
[ "$(inst_rc "$out")" != "0" ] && [ "$(inst_pl "$out")" = "SEED" ] && rc=0 || { rc=1; echo "      huge MAX_LANES -> '$out'"; }
ck "install.sh refuses an out-of-range limit (>=2**63, where [ errors and the gate fails OPEN)" $rc
# ⛔ LEADING ZEROS (P1/P2, second review round, 2026-10-14): install.sh's `''|*[!0-9]*` accepted
# `08`, rendered it into the plist and exited 0 — while the loop now COERCES it to the default, so
# the plist would LIE about the ceiling. Refusing loudly is the only consistent behaviour: a value
# this installer accepts must be the value the loop uses. Pre-fix this case exits 0 (RED).
out="$(run_inst "$(mk_sb)" CYC=08)"
[ "$(inst_rc "$out")" != "0" ] && [ "$(inst_pl "$out")" = "SEED" ] && rc=0 || { rc=1; echo "      CYC=08 -> '$out'"; }
ck "install.sh refuses a leading-zero limit AND leaves the live plist untouched" $rc
# ⛔ CYC=0 (P3, third review round, 2026-10-14): a VALID integer that passes the range loop and then
# makes the loop `sleep 0` — a zero-delay cycle that re-hits the GitHub API. Refused here, floored in
# the loop, so the two ends cannot disagree. Pre-fix this case exits 0 (RED).
out="$(run_inst "$(mk_sb)" CYC=0)"
[ "$(inst_rc "$out")" != "0" ] && [ "$(inst_pl "$out")" = "SEED" ] && rc=0 || { rc=1; echo "      CYC=0 -> '$out'"; }
ck "install.sh refuses CYC=0 (a zero-delay cycle) and leaves the live plist untouched" $rc
# ⛔ AND A FLOOR ABOVE THE BATCH IS REFUSED, NOT SILENTLY CLAMPED (review cycle 12, P2). `floor_norm` clamps
# `PRODUCT_FLOOR` to `[0, BATCH]` at runtime, so an installer that ACCEPTED `BATCH=2 PRODUCT_FLOOR=9` rendered
# a plist stating a floor the loop never uses — the same "a value this installer accepts must be the value the
# loop uses" contract the CYC=0 and leading-zero refusals exist for. It runs through `run_inst`/`mk_sb` like
# its siblings: the sandbox stubs the preflight binaries, so the validator is REACHED on Linux too — asserting
# the reason without that stub is what failed in CI on a Linux runner (the preflight died first, rc non-zero,
# message unrelated: the check graded the wrong failure).
SBF="$(mk_sb)"; out="$(run_inst "$SBF" BATCH=2 PRODUCT_FLOOR=9)"
[ "$(inst_rc "$out")" != "0" ] && [ "$(inst_pl "$out")" = "SEED" ] && rc=0 || { rc=1; echo "      PRODUCT_FLOOR=9 BATCH=2 -> '$out'"; }
ck "install.sh refuses a PRODUCT_FLOOR above BATCH and leaves the live plist untouched" $rc
grep -qF 'is above BATCH' "$SBF/out" && rc=0 || { rc=1; echo "      stderr: $(cat "$SBF/out")"; }
ck "install.sh refuses it for the BATCH reason, naming the clamp the loop applies" $rc
# Non-vacuity in both directions: the floor may equal the batch, and 0 (which DISABLES it) must install.
SBF2="$(mk_sb)"; out="$(run_inst "$SBF2" BATCH=3 PRODUCT_FLOOR=3)"
[ "$(inst_rc "$out")" = "0" ] && rc=0 || { rc=1; echo "      PRODUCT_FLOOR=3 BATCH=3 -> '$out'"; }
ck "install.sh accepts PRODUCT_FLOOR equal to BATCH (the refusal is a bound, not a blanket)" $rc
# ⛔ AND IT MUST ACCEPT A BATCH THE LOOP NORMALISES (review cycle 23, P2; the PREMISE corrected in cycle 24).
# The refusal compared the floor with the RAW `BATCH`, but `floor_norm` reads a batch of `0` as 1 — so an
# explicit `BATCH=0 PRODUCT_FLOOR=1`, a value the installer accepts elsewhere and the loop honours, was
# refused; following that refusal would have meant setting `PRODUCT_FLOOR=0`, which DISABLES the floor.
# ⚠️ THIS IS NOT THE SHIPPED DEFAULT: `install.sh:113` is `BATCH="${BATCH:-2}"`, which is what `__BATCH__` is
# rendered from, and README/ARCHITECTURE/the live plist all say 2. The earlier wording claimed the default
# install was refused, which was false (1 ≤ 2 passed on both sides) — do not restore it.
SBF0="$(mk_sb)"; out="$(run_inst "$SBF0" BATCH=0 PRODUCT_FLOOR=1)"
[ "$(inst_rc "$out")" = "0" ] && rc=0 || { rc=1; echo "      BATCH=0 PRODUCT_FLOOR=1 -> '$out'"; }
ck "install.sh ACCEPTS an explicit BATCH=0 with PRODUCT_FLOOR=1 (the loop reads BATCH=0 as 1)" $rc
case "$(cat "$SBF0/out" 2>/dev/null)" in *"is above BATCH"*) rc=1 ;; *) rc=0 ;; esac
ck "install.sh ... and does not blame the floor for a batch it never used" $rc
SBF1="$(mk_sb)"; out="$(run_inst "$SBF1" BATCH=0 PRODUCT_FLOOR=2)"
[ "$(inst_rc "$out")" != "0" ] && rc=0 || { rc=1; echo "      BATCH=0 PRODUCT_FLOOR=2 -> '$out'"; }
ck "install.sh still refuses a floor above the NORMALISED batch (BATCH=0 PRODUCT_FLOOR=2) — the normalisation is not a blanket accept" $rc
# …and the genuine DEFAULT path (no env at all) still installs, which is what the false premise was about.
SBFD="$(mk_sb)"; out="$(run_inst "$SBFD")"
[ "$(inst_rc "$out")" = "0" ] && rc=0 || { rc=1; echo "      no env (shipped defaults) -> '$out'"; }
ck "install.sh accepts a DEFAULT install (BATCH=2 PRODUCT_FLOOR=1, both from the file)" $rc
SBF3="$(mk_sb)"; out="$(run_inst "$SBF3" PRODUCT_FLOOR=0)"
[ "$(inst_rc "$out")" = "0" ] && rc=0 || { rc=1; echo "      PRODUCT_FLOOR=0 -> '$out'"; }
ck "install.sh accepts PRODUCT_FLOOR=0, which DISABLES the floor (and is not an unreachable value)" $rc
# ⛔ AND ITS LEADING-ZERO REFUSAL CARRIES THE FLOOR-SPECIFIC REASON (review cycle 17, P2): the shared sentence
# promises the loop "would silently coerce it to the default", but `floor_norm` reads base 10, so `00` is 0 —
# the value that DISABLES the floor. Refused either way; the message must name what would actually happen.
SBF4="$(mk_sb)"; out="$(run_inst "$SBF4" PRODUCT_FLOOR=00)"
[ "$(inst_rc "$out")" != "0" ] && [ "$(inst_pl "$out")" = "SEED" ] && rc=0 || { rc=1; echo "      PRODUCT_FLOOR=00 -> '$out'"; }
ck "install.sh refuses PRODUCT_FLOOR=00 and leaves the live plist untouched" $rc
grep -qF 'DISABLES the floor' "$SBF4/out" && rc=0 || { rc=1; echo "      stderr: $(cat "$SBF4/out")"; }
ck "install.sh refuses PRODUCT_FLOOR=00 for the DISABLE reason, not the shared coerce-to-default one" $rc
# ⛔ AND THE REASON MUST NAME *THIS* VALUE (review cycle 24, P2). The floor-specific sentence hardcoded `'00'`,
# so `01`-`09` were refused with a consequence that does not apply to them: `floor_norm` reads `08` in base 10
# as 8 (then clamps it to BATCH) — neither 0 nor "the default 1". Driven, not grepped: the message must carry
# the computed value and the CLAMP consequence, and must not claim the floor is disabled.
SBF8="$(mk_sb)"; out="$(run_inst "$SBF8" PRODUCT_FLOOR=08)"
[ "$(inst_rc "$out")" != "0" ] && rc=0 || { rc=1; echo "      PRODUCT_FLOOR=08 -> '$out'"; }
ck "install.sh refuses PRODUCT_FLOOR=08 (a value this installer accepts must be the value the loop uses)" $rc
case "$(cat "$SBF8/out" 2>/dev/null)" in
  *"'08' is 8"*"CLAMPED to BATCH"*) rc=0 ;;
  *) rc=1; echo "      stderr: $(cat "$SBF8/out" 2>/dev/null)"; ;;
esac
ck "install.sh names the value the LOOP computes for 08 (8, clamped), not the '00 is 0' example" $rc
case "$(cat "$SBF8/out" 2>/dev/null)" in *"DISABLES the floor"*) rc=1 ;; *) rc=0 ;; esac
ck "install.sh ... and does not claim 08 disables the floor" $rc
# ⛔ AND IT CLAIMS A CLAMP ONLY WHEN THE LOOP WOULD CLAMP (review cycle 25, P2). `floor_norm` clamps only a
# value ABOVE the batch, so `BATCH=20 PRODUCT_FLOOR=08` uses exactly 8 — the previous sentence asserted the
# clamp for the whole leading-zero class, the same "the reason must be the one that applies" defect cycle 24
# removed from the `'00'` example. Both sides driven: above the batch CLAMPS, inside it does not.
SBF8B="$(mk_sb)"; out="$(run_inst "$SBF8B" BATCH=20 PRODUCT_FLOOR=08)"
[ "$(inst_rc "$out")" != "0" ] && rc=0 || { rc=1; echo "      BATCH=20 PRODUCT_FLOOR=08 -> '$out'"; }
ck "install.sh still refuses PRODUCT_FLOOR=08 with a batch large enough to hold it" $rc
case "$(cat "$SBF8B/out" 2>/dev/null)" in
  *"inside BATCH (20)"*"would use 8"*) rc=0 ;;
  *) rc=1; echo "      stderr: $(cat "$SBF8B/out" 2>/dev/null)"; ;;
esac
ck "install.sh says 08 is USED AS 8 inside BATCH, not that it is clamped" $rc
case "$(cat "$SBF8B/out" 2>/dev/null)" in *CLAMPED*) rc=1 ;; *) rc=0 ;; esac
ck "install.sh ... and does not claim a clamp that would not happen" $rc
# Non-vacuity: the floor is 5, not a blanket refusal — a deliberate small cycle must still install.
SB5="$(mk_sb)"; out="$(run_inst "$SB5" CYC=5)"
[ "$(inst_rc "$out")" = "0" ] && rc=0 || { rc=1; echo "      CYC=5 -> '$out'"; }
ck "install.sh accepts a deliberate small CYC=5 (the floor is not a blanket refusal)" $rc
out="$(run_inst "$(mk_sb)" OR='__MAX_LANES__')"
[ "$(inst_rc "$out")" != "0" ] && [ "$(inst_pl "$out")" = "SEED" ] && rc=0 || { rc=1; echo "      OR=__MAX_LANES__ -> '$out'"; }
ck "install.sh refuses a value carrying a template token (a later sed rule would rewrite it)" $rc
SBT="$(mk_sb)"; run_inst "$SBT" MAX_LANES=4x >/dev/null
# Capture, then classify in the SHELL — never `ls … | grep -q`, whose false negative under
# `pipefail` would report GREEN on a regression (this assertion pins the ABSENCE of a temp plist)
# — the #864 class, and the guard does not scan this file's directory tree for it.
case "$(ls "$SBT/Library/LaunchAgents/" 2>/dev/null || true)" in *'.new.'*) rc=1 ;; *) rc=0 ;; esac
ck "a rejected render leaves no temp plist behind (the render is not atomic by accident)" $rc
# ⛔ The cases above fail BEFORE the render or AFTER it completes, so neither drives the window
# BETWEEN `RENDER=` and the `mv`. The render runs under `set -euo pipefail`, so a template read that
# fails aborts THERE, orphaning `*.plist.new.<pid>` in LaunchAgents with nothing to prune it
# (README §7.5 tracks exactly this unbounded growth). Make the template unreadable in a COPY so sed
# cannot open its input, and assert the sandbox holds ONLY the seed afterwards -- the `trap ... EXIT`
# is what makes this pass, so deleting it turns this red.
HDR="$TMP/hdr"; rm -rf "$HDR"; mkdir -p "$HDR"; cp "$HERE"/*.sh "$HERE/launchd.plist.template" "$HDR/" 2>/dev/null
chmod 000 "$HDR/launchd.plist.template"
SBR="$(mk_sb)"; out="$(run_inst_at "$HDR/install.sh" "$SBR")"
[ "$(inst_rc "$out")" != "0" ] && [ "$(inst_pl "$out")" = "SEED" ] && rc=0 || { rc=1; echo "      unreadable template -> '$out'"; }
ck "a render that cannot read its template fails instead of installing a truncated plist" $rc
# ⛔ NON-VACUITY, and it is not hypothetical: run this suite from a directory that is NOT a git
# checkout (a plain `cp` of the harness, say) and install.sh dies at its "not a git checkout" guard
# BEFORE the render -- leaving no orphan, so the pin below would pass while testing nothing.
#
# ⛔ Naming the template is NOT a sufficient proxy for "reached the render": install.sh's
# `[ -f "$TEMPLATE" ] || die "missing template: $TEMPLATE"` runs BEFORE `RENDER=` and names the
# template too. So if the `cp` above fails for the TEMPLATE only (its stderr is swallowed by
# `2>/dev/null`), the run dies at that guard and a name-matching check would call it "reached the
# render" -- three greens with the render never entered, which is the vacuity this is meant to
# forbid. Assert the FIXTURE, then require the RENDER-side failure specifically.
[ -f "$HDR/launchd.plist.template" ] && [ ! -r "$HDR/launchd.plist.template" ] && rc=0 || { rc=1; echo "      fixture precondition failed: the template copy is absent or still readable"; }
ck "the unreadable-template fixture is in place (a swallowed cp must be loud, not silent)" $rc
# ⛔ A here-string, not a pipe: `printf … | grep -q` lets grep exit at its first match while the
# writer is still pushing, so the writer takes SIGPIPE and `pipefail` reports 141 — the false
# negative this repo bans (`scripts/check-no-sigpipe-grep.sh`, #841).
grep -q 'Permission denied' <<<"$out" && rc=0 || { rc=1; echo "      the run did not fail AT THE RENDER: '$out'"; }
ck "the unreadable-template case failed at the render, not at an earlier guard that also names it" $rc
case "$(ls "$SBR/Library/LaunchAgents/" 2>/dev/null || true)" in *'.new.'*) rc=1 ;; *) rc=0 ;; esac
ck "a render that ABORTS mid-flight leaves no orphan temp plist (the path rm -f alone misses)" $rc
chmod 644 "$HDR/launchd.plist.template"
# ⛔ ATOMICITY ITSELF is untested by the three cases above: they all fail BEFORE the render, so a
# render that wrote straight into the live plist would blindside only one that failed AFTER it. Force
# that path with a template token that has no substitution rule, in a COPY of the harness.
HD="$TMP/hd"; mkdir -p "$HD"; cp "$HERE"/*.sh "$HERE/launchd.plist.template" "$HD/" 2>/dev/null
printf '\n\t<key>__NORULE__</key>\n\t<string>x</string>\n' >> "$HD/launchd.plist.template"
out="$(run_inst_at "$HD/install.sh" "$(mk_sb)")"
[ "$(inst_rc "$out")" != "0" ] && [ "$(inst_pl "$out")" = "SEED" ] && rc=0 || { rc=1; echo "      post-render rejection -> '$out'"; }
ck "a POST-render rejection leaves the live plist intact (the render is atomic)" $rc
SBG="$(mk_sb)"; out="$(run_inst "$SBG")"
[ "$(inst_rc "$out")" = "0" ] && rc=0 || { rc=1; echo "      a clean render failed: '$out'"; }
ck "install.sh still installs the happy path (the new guards do not refuse a legal config)" $rc
SBPL="$SBG/Library/LaunchAgents/$TPL"
grep -q '__[A-Z_]*__' "$SBPL" && rc=1 || rc=0
ck "no unrendered token survives a successful render (driven through the real installer)" $rc
plutil -lint "$SBPL" >/dev/null 2>&1 && rc=0 || rc=1
ck "the freshly rendered plist is valid XML" $rc
else
  skipd "install.sh's render guards, DRIVEN (§6 follow-on) — install.sh is macOS-only (launchd); skipped on $PLATFORM"
fi

# ── 6f) the sandbox LABEL seam (agent-infra#1996) ──────────────────────────────────────────────
# launchd labels are GLOBAL: a plist rendered under a throwaway $HOME still addresses the PRODUCTION
# job by name when it carries the production label, so a `launchctl bootout` addressed at a sandbox
# plist reaches the controller the box is actually RUNNING — a "sandboxed" test can silence
# production, and this suite's own `launchctl` stub would have answered for it. Two halves here: the
# real installer driven under a TEST label, and `label_guard` driven in all four directions.
# ⛔ THE OTHER TWO HALVES OF THIS SECTION ARE NOT RE-ASSERTED HERE, AND THAT IS DELIBERATE: the
# `WorkingDirectory` property belongs to PR #2020 (main's measured answer is the install dir, not the
# checkout — docs/ops/fleet-harness-baseline.md:162) and the watchdog — its plist, its decisions and
# its disarm sentinel — belongs to PR #1986, which owns that agent. One implementation, one
# description, one suite; a second copy here is how a fleet ends up with two disarm sentinels.
WDSB=""
if on_darwin; then
WDSB="$(mk_sb)"
out="$(run_inst "$WDSB")"
[ "$(inst_rc "$out")" = "0" ] && rc=0 || { rc=1; echo "      install for §6f failed: '$out'"; }
ck "§6f: install.sh installs cleanly under the sandbox label" $rc
PLW="$WDSB/Library/LaunchAgents/$TPL"
lbl="$(plutil -extract Label raw "$PLW" 2>/dev/null || echo MISSING)"
[ "$lbl" = "$TEST_LABEL" ] && rc=0 || { rc=1; echo "      rendered Label='$lbl', wanted '$TEST_LABEL'"; }
ck "§6f: the sandbox install carries the TEST label" $rc
# ⛔ NOT `grep -F "$PROD_LABEL"`: the TEST label CONTAINS the production one as a substring
# (`…-loop-test`), so a substring read would fail on a correctly-labelled plist — the arm would be red
# for the wrong reason and would be "fixed" by weakening it. The production label only counts when it
# is NOT followed by a `-suffix`.
# ⛔ XML COMMENTS ARE STRIPPED FIRST. The templates DOCUMENT the production label in prose, and a
# comment cannot address launchd — but a plain grep over the file reads it as a hit and the arm goes
# red on a correctly-labelled plist. Only the EFFECTIVE plist counts.
if sed '/<!--/,/-->/d' "$PLW" 2>/dev/null | grep -qE "$PROD_LABEL([^a-z-]|$)"; then rc=1; else rc=0; fi
ck "§6f: ...and no sandbox plist names the PRODUCTION label anywhere" $rc
else
  skipd "§6f: the sandbox-label render — install.sh is macOS-only (launchd); skipped on $PLATFORM"
fi

# §6f (second half) drives `label_guard` as the PURE decision it is (label, HOME, real home), so the
# rule is proven in BOTH directions without ever installing into the real LaunchAgents — a test that
# reproduced the failure would be the failure. No launchd and no macOS: this runs everywhere.
awk '/^label_guard\(\) \{/,/^}/' "$INST" > "$TMP/labelguard.sh"
if need "$TMP/labelguard.sh" "§6f: extract label_guard from install.sh"; then
  # shellcheck source=/dev/null
  . "$TMP/labelguard.sh"
  BASE_LABEL="$PROD_LABEL"
  PROD_WD_LABEL="com.eldato.orchestrator-watchdog"
  # A "sandbox home" for the guard: a throwaway dir, NOT $WDSB — that one exists only on macOS, and
  # the guard's rule must be provable on every host (`label_guard` never touches launchd).
  LG_SB="$TMP/labelguard-sb"; mkdir -p "$LG_SB"
  label_guard "$PROD_LABEL" "$HOME" "$HOME"; lg_prod=$?
  label_guard "$TEST_LABEL" "$LG_SB" "$HOME"; lg_sbx=$?
  lg_msg="$( label_guard "$TEST_LABEL" "$HOME" "$HOME" 2>&1 )"; lg_real=$?
  [ "$lg_prod" = "0" ] && [ "$lg_sbx" = "0" ] && [ "$lg_real" = "1" ] && rc=0 \
    || { rc=1; echo "      prod=$lg_prod sandbox=$lg_sbx real=$lg_real"; }
  ck "§6f: the label guard allows production-on-real and test-in-sandbox, and REFUSES a test label on the real \$HOME" $rc
  grep -q 'SANDBOX seam' <<<"$lg_msg" && rc=0 || { rc=1; echo "      refusal: $lg_msg"; }
  ck "§6f: ...and the refusal names the seam" $rc
  # ⛔ THE DIRECTION THAT ACTUALLY REACHES PRODUCTION (review catch, 2026-10-18): a PRODUCTION label
  # rendered into a sandbox \$HOME. launchd resolves the label in the user domain and ignores \$HOME, so
  # that plist addresses the live controller — the half-guard this replaces allowed exactly that.
  # BOTH production labels: the loop's AND the watchdog's (a second production label the guard did not
  # know about is installable from a sandbox — the same defect, one job over).
  lg_msg2="$( label_guard "$PROD_LABEL" "$LG_SB" "$HOME" 2>&1 )"; lg_sbxprod=$?
  lg_msg3="$( label_guard "$PROD_WD_LABEL" "$LG_SB" "$HOME" 2>&1 )"; lg_sbxprodwd=$?
  [ "$lg_sbxprod" = "1" ] && [ "$lg_sbxprodwd" = "1" ] && rc=0 \
    || { rc=1; echo "      production-labels-in-sandbox guard: loop=$lg_sbxprod watchdog=$lg_sbxprodwd"; }
  ck "§6f: ...and it REFUSES a PRODUCTION label under a sandbox \$HOME (loop and watchdog labels)" $rc
  grep -q 'PRODUCTION label' <<<"$lg_msg2" && grep -q 'IGNORES' <<<"$lg_msg2" && rc=0 || { rc=1; echo "      refusal: $lg_msg2"; }
  ck "§6f: ...and THAT refusal explains why \$HOME does not protect anything (launchd ignores it)" $rc
fi

# ── 6g) NO TEST ADDRESSED PRODUCTION ─────────────────────────────────────────────────────────────
# The PATH stub refuses a production label (exit 97) and records every call, so this is a measurement
# over the WHOLE run, not a promise about one section: every install.sh invocation in this file goes
# through the test label, and any call that named a live job would be listed here.
if [ -f "$LM_LOG" ] && grep -qE "$PROD_LABEL([^a-z-]|$)|$PROD_WD_LABEL([^a-z-]|$)" "$LM_LOG"; then
  rc=1; echo "      a selftest addressed a production label:"; grep -E "$PROD_LABEL([^a-z-]|$)|$PROD_WD_LABEL([^a-z-]|$)" "$LM_LOG" | head -3
else
  rc=0
fi
ck "§6g: NO launchd call in this run addressed a production label (loop AND watchdog; the sandbox label held)" $rc

# ── 20) a TERM'd controller EXITS; the lock/claim is not released while it is still running ──
# agent-infra#1715. The shipped trap was `trap 'rm -f "$LOCKF"' EXIT INT TERM`: for INT/TERM a
# handler that RETURNS resumes the interrupted command loop, so the documented stop path
# (`pkill -f orch-loop.sh`, README §6) deleted the lock while the controller kept sweeping,
# reviewing and merging — and the next start passed acq(), giving two autonomous merge controllers
# on one PR queue. Driven against the SHIPPED lock+trap block (extracted, not re-implemented) with a
# stub loop, so it fails on the pre-fix copy. The invariant asserted is "the lock and the process
# go away together": a released lock may only ever be observed as the process is leaving.
sed -n '/^# single-instance lock/,/^trap .rm -f "\$LOCKF".*$/p' "$LOOP" > "$TMP/lockblock.sh"
if need "$TMP/lockblock.sh" "the lock+trap block is extracted from the shipped orch-loop.sh"; then
  LK="$TMP/LK"; mkdir -p "$LK/state"
  { echo 'set -u'; echo "O='$LK'"; cat "$TMP/lockblock.sh"; echo 'while :; do sleep 0.2; done'; } > "$LK/drive.sh"
  bash -n "$LK/drive.sh" && rc=0 || rc=1
  ck "the lock-trap driver parses" $rc
  rm -f "$LK/.orch.lock"
  bash "$LK/drive.sh" & cpid=$!
  i=0; while [ ! -f "$LK/.orch.lock" ] && [ $i -lt 20 ]; do sleep 0.1; i=$((i+1)); done
  [ -f "$LK/.orch.lock" ] && rc=0 || { rc=1; echo "      the stub controller never took the lock"; }
  ck "the controller takes the single-instance lock" $rc
  [ "$(cat "$LK/.orch.lock" 2>/dev/null)" = "$cpid" ] && rc=0 || rc=1
  ck "the lock records the controller's pid" $rc

  kill -TERM "$cpid" 2>/dev/null
  released_while_alive=0; dead=0; i=0
  while [ $i -lt 100 ]; do
    if [ ! -f "$LK/.orch.lock" ]; then
      # The lock is gone: the controller must be on its way out, not resuming the loop. Poll rather
      # than sample once, so the few instructions between the EXIT trap's rm and the process dying
      # are not read as the defect.
      j=0; while [ $j -lt 10 ]; do kill -0 "$cpid" 2>/dev/null || { dead=1; break; }; sleep 0.1; j=$((j+1)); done
      [ "$dead" = "1" ] || released_while_alive=1
      break
    fi
    kill -0 "$cpid" 2>/dev/null || break
    sleep 0.05; i=$((i+1))
  done
  [ "$released_while_alive" = "0" ] && rc=0 || rc=1
  ck "a TERM releases the lock only as the controller exits, never while it keeps running" $rc
  [ "$dead" = "1" ] && rc=0 || { rc=1; kill -9 "$cpid" 2>/dev/null; }
  wait "$cpid" 2>/dev/null
  ck "a TERM'd controller actually exits" $rc
  [ -f "$LK/.orch.lock" ] && rc=1 || rc=0
  ck "the exited controller released its lock via the EXIT trap" $rc

  # The same defect on merge-one.sh's per-PR claim (§5.1b): a TERM must not free the claim while
  # the worker keeps reviewing/merging, which let a second worker spawn for the same head.
  sed -n '/^CLAIM="\$O\/state\/mergeclaim-\$PR.lock"/,/^trap .rm -f "\$CLAIM".*$/p' "$MERGE" > "$TMP/claimtrap.sh"
  if need "$TMP/claimtrap.sh" "the claim+trap block is extracted from the shipped merge-one.sh"; then
    { echo 'set -u'; echo "O='$LK'"; echo 'PR=9191'; echo "L='$LK/claim'"; cat "$TMP/claimtrap.sh"; echo 'while :; do sleep 0.2; done'; } > "$LK/mdrive.sh"
    bash -n "$LK/mdrive.sh" && rc=0 || rc=1
    ck "the claim-trap driver parses" $rc
    rm -f "$LK/state/mergeclaim-9191.lock"
    bash "$LK/mdrive.sh" & mpid=$!
    i=0; while [ ! -f "$LK/state/mergeclaim-9191.lock" ] && [ $i -lt 20 ]; do sleep 0.1; i=$((i+1)); done
    [ -f "$LK/state/mergeclaim-9191.lock" ] && rc=0 || { rc=1; echo "      merge-one.sh never took the claim"; }
    ck "the worker takes the per-PR claim" $rc
    kill -TERM "$mpid" 2>/dev/null
    m_rel=0; m_dead=0; i=0
    while [ $i -lt 100 ]; do
      if [ ! -f "$LK/state/mergeclaim-9191.lock" ]; then
        j=0; while [ $j -lt 10 ]; do kill -0 "$mpid" 2>/dev/null || { m_dead=1; break; }; sleep 0.1; j=$((j+1)); done
        [ "$m_dead" = "1" ] || m_rel=1
        break
      fi
      kill -0 "$mpid" 2>/dev/null || break
      sleep 0.05; i=$((i+1))
    done
    [ "$m_rel" = "0" ] && rc=0 || rc=1
    ck "a TERM frees the per-PR claim only as the worker exits" $rc
    [ "$m_dead" = "1" ] && rc=0 || { rc=1; kill -9 "$mpid" 2>/dev/null; }
    wait "$mpid" 2>/dev/null
    ck "a TERM'd merge-one.sh actually exits" $rc
  fi

  # The cycle sleep must be INTERRUPTIBLE: bash runs a trap only after the current foreground
  # command completes, so a bare `sleep "$CYC"` deferred the stop for up to the whole cycle
  # (measured 5.07s of a 6s sleep, vs 0.09s for `sleep … & wait $!`). Drive the SHIPPED line with
  # CYC=8 and require the stop inside 4s, so a revert to the bare sleep fails here.
  # ⛔ Extract from the JIT assignment THROUGH the backgrounded sleep, not just the sleep line
  # (agent-infra#1709 rec 4): the shipped sleep is now `sleep $(( CYC - JIT + RANDOM % (2*JIT+1) ))`,
  # so JIT must be in the extracted driver or the arithmetic fails. A bare `grep 'sleep "$CYC"'`
  # matched the pre-jitter form ONLY and silently extracted nothing once jitter landed.
  # ⛔ EXTRACT THROUGH THE ENCLOSING `fi`, NOT ONLY TO THE FIRST `& wait $!` (agent-infra#2293). The
  # shipped nap is now `if [ "${FORK_STARVED:-0}" = "1" ]; then fork_free_sleep … ; else sleep … & wait $!; fi`,
  # so ending the extraction at the `wait` line handed the driver an UNCLOSED `if` — `bash -n` failed and
  # this whole section went red (4 checks) on a tree whose shipped code is correct. The lookahead is
  # BOUNDED: a tree with no `fi` after the wait keeps the old behaviour (extract through the wait line)
  # rather than swallowing the rest of orch-loop.sh into the driver.
  awk '
    /^  JIT=/ { f=1 }
    f { buf[++n] = $0 }
    f && /& wait \$!$/ { w = n }
    f && w && /^  fi$/ { last = n; done = 1; exit }
    f && w && (n - w) >= 8 { last = w; done = 1; exit }
    END { m = (done ? last : n); for (i = 1; i <= m; i++) print buf[i] }
  ' "$LOOP" > "$TMP/cycsleep.sh"
  if need "$TMP/cycsleep.sh" "the interruptible cycle sleep is extracted from the shipped orch-loop.sh"; then
    # The extraction must still carry the JITTER, or a revert to a fixed interval would pass the
    # interruptibility check below while re-introducing the thundering herd it exists to prevent.
    grep -q 'RANDOM' "$TMP/cycsleep.sh" && rc=0 || rc=1
    ck "the shipped cycle sleep is jittered (±20% of CYC), not a fixed interval" $rc
    { echo 'set -u'; echo "O='$LK'"; cat "$TMP/lockblock.sh"; echo 'CYC=8'; cat "$TMP/cycsleep.sh"; } > "$LK/cyc.sh"
    bash -n "$LK/cyc.sh" && rc=0 || rc=1
    ck "the cycle-sleep driver parses" $rc
    # Non-vacuity: the driver must OWN the lock (a leftover lock would make it refuse the lock and
    # exit immediately, so the "stopped inside 4s" check below would pass without ever sleeping).
    rm -f "$LK/.orch.lock"
    bash "$LK/cyc.sh" & ypid=$!
    i=0; while [ ! -f "$LK/.orch.lock" ] && [ $i -lt 20 ]; do sleep 0.1; i=$((i+1)); done
    [ "$(cat "$LK/.orch.lock" 2>/dev/null)" = "$ypid" ] && rc=0 || { rc=1; echo "      lock='$(cat "$LK/.orch.lock" 2>/dev/null)' != driver pid $ypid"; }
    ck "the cycle-sleep driver acquired the lock (it really is in the CYC sleep)" $rc
    sleep 0.5
    kill -0 "$ypid" 2>/dev/null && rc=0 || rc=1
    ck "the cycle-sleep driver is still sleeping when TERM arrives" $rc
    kill -TERM "$ypid" 2>/dev/null
    ydead=0; i=0
    while [ $i -lt 40 ]; do kill -0 "$ypid" 2>/dev/null || { ydead=1; break; }; sleep 0.1; i=$((i+1)); done
    [ "$ydead" = "1" ] && rc=0 || { rc=1; kill -9 "$ypid" 2>/dev/null; }
    wait "$ypid" 2>/dev/null
    ck "the shipped cycle sleep is interrupted by TERM inside CYC (stopped <4s, not 8s)" $rc
    # ⛔ DEFENCE IN DEPTH (P1, second review round, 2026-10-14). The predicate now coerces CYC=08
    # to 240 before the loop, but that is not the only guard: give the EXTRACTED shipped lines
    # CYC=08 DIRECTLY and wrap them in the shipped `while true` shape. With the old
    # `JIT=$(( CYC / 5 ))`, /bin/bash 3.2.57 printed `08: value too great for base` and DISCARDED
    # the loop — the driver echoed CYCLES=1 and exited 0, i.e. a relaunch-per-cycle controller
    # under KeepAlive. `10#${CYC}` keeps it cycling. Break at 3 so a failure (1) is distinguishable
    # from a pass (3); `sleep` is stubbed so the driver is instant.
    { echo 'set -u'; echo 'CYC=08'; echo 'sleep() { :; }'; echo 'n=0'
      echo 'while true; do'
      echo '  n=$((n+1))'
      cat "$TMP/cycsleep.sh"
      echo '  [ "$n" -ge 3 ] && break'
      echo 'done'
      echo 'echo "CYCLES=$n"'
    } > "$LK/cyc08.sh"
    out08="$(bash "$LK/cyc08.sh" 2>&1)"
    case "$out08" in *CYCLES=3*) rc=0;; *) rc=1; echo "      CYC=08 did not keep the loop alive: $out08";; esac
    ck "CYC=08 does not discard the controller's while loop (arithmetic read in base 10)" $rc
  fi

  # Reclamation must be REAL, not silently skipped: a lock whose PID is dead is reclaimed by the
  # next start (the SIGKILL/reboot path), while one held by a LIVE pid is refused. Without the
  # negative control, "reclaimed" and "silently overwritten" would be the same test. Deliberately
  # LAST in this section: the live-pid case intentionally leaves a lock in place.
  { echo 'set -u'; echo "O='$LK'"; cat "$TMP/lockblock.sh"; echo 'echo ACQUIRED'; } > "$LK/acquire.sh"
  bash -n "$LK/acquire.sh" && rc=0 || rc=1
  ck "the stale-lock driver parses" $rc
  printf '999999\n' > "$LK/.orch.lock"
  out="$(bash "$LK/acquire.sh" 2>&1)"
  case "$out" in *ACQUIRED*) rc=0;; *) rc=1; echo "      got '$out'";; esac
  ck "a stale lock (dead pid) is reclaimed by the next start" $rc
  printf '%s\n' "$$" > "$LK/.orch.lock"
  out="$(bash "$LK/acquire.sh" 2>&1)"
  case "$out" in *ACQUIRED*) rc=1; echo "      a live lock was stolen";; *) rc=0;; esac
  ck "a lock held by a LIVE pid is NOT stolen (reclamation is not a silent overwrite)" $rc
fi

# ── 20) the port-drift check detects that the tortoise source moved (#1712) ──────
# `check-port-drift.sh` is the guard that stops the follow-up tortoise PR from deleting the only
# tree carrying an unported fix. A guard nobody ever saw fail is not a guard, so it is driven here
# against fixtures. Two failure modes are pinned, and they are different:
#   * the SOURCE moved (a file changed / was added / was removed at the ref) -> exit 1 and the
#     offending path is named;
#   * the WORKING TREE moved but the ref did not -> exit 0. This is not hypothetical: it was the
#     first version of this check's own defect. Compare a worktree instead of a ref and, on a
#     checkout 3 commits behind origin/main with its changes already landed in the copy, the check
#     reports "no drift" against a source that has moved — the stale-flag false pass.
# The driver copies the SHIPPED script verbatim (only the pin beside it is synthetic), so deleting
# the ref comparison in the served check turns these red.
if command -v git >/dev/null 2>&1; then
  W="$TMP/pd-src"; C="$TMP/pd-chk"; mkdir -p "$W/operations/orchestrator-harness" "$C"
  cp "$HERE/check-port-drift.sh" "$C/check-port-drift.sh"
  cp "$HERE/port-provenance.txt" "$C/port-provenance.txt"
  G="git -C $W -c user.email=t@t -c user.name=t -c commit.gpgsign=false"
  printf 'loop v1\n' > "$W/operations/orchestrator-harness/orch-loop.sh"
  printf 'readme v1\n' > "$W/operations/orchestrator-harness/README.md"
  $G init -q >/dev/null 2>&1 && $G add -A >/dev/null 2>&1 && $G commit -qm base >/dev/null 2>&1
  pd() { bash "$C/check-port-drift.sh" --tortoise "$W" --ref HEAD --no-fetch "$@" 2>&1; }
  if [ -f "$W/.git/HEAD" ]; then
    pd --repin >/dev/null 2>&1
    pd >"$TMP/pd-ok.out" 2>&1 && rc=0 || rc=1
    ck "port-drift: a tree at the pinned revision reports no drift" $rc
    # (a) the source changed at the ref
    printf 'loop v2\n' > "$W/operations/orchestrator-harness/orch-loop.sh"
    $G add -A >/dev/null 2>&1; $G commit -qm change >/dev/null 2>&1
    out="$(pd)"; rc=$?
    [ "$rc" -eq 1 ] && case "$out" in *orch-loop.sh*) rc=0;; *) rc=1; echo "      drift not attributed: $out";; esac || rc=1
    ck "port-drift: a CHANGED file at the ref fails and is NAMED" $rc
    # (b) the source ADDED a file the pin never saw
    printf 'new\n' > "$W/operations/orchestrator-harness/new-thing.sh"
    $G add -A >/dev/null 2>&1; $G commit -qm add >/dev/null 2>&1
    out="$(pd)"; rc=$?
    [ "$rc" -eq 1 ] && case "$out" in *new-thing.sh*) rc=0;; *) rc=1;; esac || rc=1
    ck "port-drift: a file ADDED at the ref fails (it cannot be in the copy)" $rc
    # (c) the source REMOVED a pinned file
    $G rm -q operations/orchestrator-harness/README.md >/dev/null 2>&1; $G commit -qm rm >/dev/null 2>&1
    out="$(pd)"; rc=$?
    [ "$rc" -eq 1 ] && case "$out" in *README.md*) rc=0;; *) rc=1;; esac || rc=1
    ck "port-drift: a pinned file REMOVED at the ref fails" $rc
    # (d) THE FALSE-PASS GUARD: the ref is clean again, and the WORKING TREE is dirtied without a
    # commit. The ref is what decides, so this must stay GREEN — a worktree comparison hashes
    # 'dirty v9' here and turns it red (which is what the first version of this check did).
    printf 'loop v3\n' > "$W/operations/orchestrator-harness/orch-loop.sh"
    printf 'readme v3\n' > "$W/operations/orchestrator-harness/README.md"
    $G add -A >/dev/null 2>&1; $G commit -qm restore >/dev/null 2>&1
    pd --repin >/dev/null 2>&1
    printf 'DIRTY WORKTREE ONLY\n' > "$W/operations/orchestrator-harness/orch-loop.sh"
    pd >/dev/null 2>&1 && rc=0 || rc=1
    ck "port-drift: an uncommitted WORKING-TREE edit does NOT read as drift (the ref decides)" $rc
    # (e) the harness is gone at the ref -> the relocation is complete, not "cannot verify"
    $G checkout -q -- . >/dev/null 2>&1
    $G rm -rq operations/orchestrator-harness >/dev/null 2>&1; $G commit -qm gone >/dev/null 2>&1
    out="$(pd)"; rc=$?
    [ "$rc" -eq 0 ] && case "$out" in *"relocation is complete"*) rc=0;; *) rc=1;; esac || rc=1
    ck "port-drift: a tortoise tree that no longer carries the harness exits 0 (removal is the goal)" $rc
    # (f) cannot-verify is NOT the same verdict: an unresolvable ref must exit 2, never 0
    bash "$C/check-port-drift.sh" --tortoise "$W" --ref no-such-ref --no-fetch >/dev/null 2>&1
    [ "$?" -eq 2 ] && rc=0 || rc=1
    ck "port-drift: an unresolvable ref exits 2, not 0 (cannot-verify is not a pass)" $rc
  else
    ck "port-drift: the fixture git repo was created" 1
  fi
else
  ck "port-drift: git is available to drive the check" 1
fi

# ── N) refresh-candidates.sh is REPO-AWARE, and a permanent failure is not a silent loop (#1736) ──
# The full contract — a repo with no pyproject.toml PROCEEDS (the venv step is not applicable, not a
# swallowed failure), the pre-flight tool is resolved per repo, `--check` gives the read-only
# verdict the cell's `start` gate uses, and orch-loop.sh distinguishes PERMANENT (stop, mark, be
# loud) from TRANSIENT (retry) — lives in its own hermetic suite. Run it here so `./selftest.sh`
# stays the one command that pins the harness; run-bash-shards.sh runs it directly in CI too.
if [ -f "$HERE/merged-not-closed.test.sh" ]; then
  if bash "$HERE/merged-not-closed.test.sh" > "$TMP/mnc.out" 2>&1; then
    ck "merged-not-closed.test.sh: repo resolution + the exit-2 fail-closed contract (#8468)" 0
  else
    ck "merged-not-closed.test.sh: repo resolution + the exit-2 fail-closed contract (#8468)" 1
    grep -E 'FAIL' "$TMP/mnc.out" | sed 's/^/      /' | tail -20
  fi
else
  ck "merged-not-closed.test.sh is present (the ported instrument has coverage)" 1
fi

# #2603: THE MERGE REMINDER'S ACTUATOR ARM. The reminder is a fleet-critical timer that until now
# lived outside version control; its arm decides whether to spend a rail attempt, so its gates are
# pinned here as well as in `scripts/run-bash-shards.sh` (CI runs both lanes from that one list —
# this block is what makes `./selftest.sh` the single local command that covers it).
if [ -f "$HERE/merge-reminder.test.sh" ]; then
  if bash "$HERE/merge-reminder.test.sh" > "$TMP/merge-reminder.out" 2>&1; then
    ck "merge-reminder.test.sh: the actuator arm is gated on evidence (#2603)" 0
  else
    ck "merge-reminder.test.sh: the actuator arm is gated on evidence (#2603)" 1
    grep -E '❌|PASS=' "$TMP/merge-reminder.out" | sed 's/^/      /' | tail -20
  fi
else
  ck "merge-reminder.test.sh is present (the actuator arm has coverage)" 1
fi

if [ -f "$HERE/refresh-scout.test.sh" ]; then
  if bash "$HERE/refresh-scout.test.sh" > "$TMP/refresh-scout.out" 2>&1; then
    ck "refresh-scout.test.sh: repo-aware scout provisioning + no silent retry (#1736)" 0
  else
    ck "refresh-scout.test.sh: repo-aware scout provisioning + no silent retry (#1736)" 1
    grep -E '❌|Summary|PASS=' "$TMP/refresh-scout.out" | sed 's/^/      /' | tail -20
  fi
else
  ck "refresh-scout.test.sh: the #1736 suite is present" 1
fi

if [ -f "$HERE/refresh-provision.test.sh" ]; then
  if bash "$HERE/refresh-provision.test.sh" > "$TMP/refresh-provision.out" 2>&1; then
    ck "refresh-provision.test.sh: a provision failure RECORDS its sub-step/rc/cause, a stale git lock is repaired by path (#2229)" 0
  else
    ck "refresh-provision.test.sh: a provision failure RECORDS its sub-step/rc/cause, a stale git lock is repaired by path (#2229)" 1
    grep -E '❌|==>' "$TMP/refresh-provision.out" | sed 's/^/      /' | tail -20
  fi
else
  ck "refresh-provision.test.sh: the #2229 suite is present" 1
fi

# #2229: ORIGINATION MUST FAIL LOUDLY. The refresh is backgrounded, so its failure is a log line — and
# the beat printed `[dispatch] skipped (merge-priority …)` for it, making "PRs outrank issues" and "issue
# work can never start" the same sentence. The suite drives the shipped pass and the shipped caller block.
if [ -f "$HERE/origination-funnel.test.sh" ]; then
  if bash "$HERE/origination-funnel.test.sh" > "$TMP/origination-funnel.out" 2>&1; then
    ck "origination-funnel.test.sh: a failed refresh is named, never masked as a priority decision (#2229)" 0
  else
    ck "origination-funnel.test.sh: a failed refresh is named, never masked as a priority decision (#2229)" 1
    grep -E '❌|==> ' "$TMP/origination-funnel.out" | sed 's/^/      /' | tail -20
  fi
else
  ck "origination-funnel.test.sh: the #2229 suite is present" 1
fi

# ── O) the sweep listing is CONDITIONAL and rate-limit-aware (#1762) ─────────────
# The full contract — the listing is a REST `gh api` call carrying the stored ETag, a 304 reuses the
# listing and skips the per-PR reads, response headers (not `/rate_limit`) drive the health decision,
# a rate-limit failure is distinct from a network one and records the reset — lives in its own
# hermetic suite, driven against the shipped block with a stub `gh`. Run it here so `./selftest.sh`
# stays the one command that pins the harness.
if [ -f "$HERE/sweep-quota.test.sh" ]; then
  if bash "$HERE/sweep-quota.test.sh" > "$TMP/sweep-quota.out" 2>&1; then
    ck "sweep-quota.test.sh: conditional listing + rate-limit headers (#1762)" 0
  else
    ck "sweep-quota.test.sh: conditional listing + rate-limit headers (#1762)" 1
    grep -E '❌|Summary|PASS=' "$TMP/sweep-quota.out" | sed 's/^/      /' | tail -20
  fi
else
  ck "sweep-quota.test.sh: the #1762 suite is present" 1
fi

# ── 21) deployed-harness provenance and drift (#1745) ────────────────────────────
# The cloud cells got a provenance layer in #1790; the LAPTOP stayed uncovered —
# `cd ~/orchestrator && git rev-parse --show-toplevel` printed "fatal: not a git repository", so
# "which commit is this box running?" had NO answer. Two shipped halves close it: install.sh writes
# $O/.agent-infra-stamp.json (the SAME cell-shaped record surface the cell supervisor writes), and
# check-deployed-drift.sh answers whether the deployed $O matches the repo. An ABSENT or UNKNOWN
# record is exit 2 and NEVER a pass — the exact failure that let the cell check bless a tree off
# main's line.
#
# The writer is driven from the SHIPPED install.sh: its provenance block is extracted between its
# own markers and sourced with a fixture HERE/O. install.sh's macOS-only gate is at its PREFLIGHT;
# the block itself is pure git + file hashing, so this section runs on every platform. The check is
# copied verbatim, so neither half can be faked by a fixture that re-implements the logic.
sed -n '/provenance (agent-infra#1745) BEGIN/,/provenance (agent-infra#1745) END/p' "$INST" > "$TMP/prov-block.body"
if need "$TMP/prov-block.body" "install.sh's provenance block is extracted (its markers are present)"; then
  { printf 'warn() { :; }\nok() { :; }\n'; cat "$TMP/prov-block.body"; } > "$TMP/prov-block.sh"
  if command -v git >/dev/null 2>&1; then
    PW="$TMP/prov-repo"; PO="$TMP/prov-o"; PC="$TMP/prov-chk"
    mkdir -p "$PW/scripts/orchestrator-harness" "$PO" "$PC"
    cp "$HERE/check-deployed-drift.sh" "$PC/check-deployed-drift.sh"
    PG="git -C $PW -c user.email=t@t -c user.name=t -c commit.gpgsign=false"
    printf 'loop v1\n' > "$PW/scripts/orchestrator-harness/orch-loop.sh"
    printf 'claims v1\n' > "$PW/scripts/orchestrator-harness/claims.sh"
    # A THIRD shipped script that is NOT one of the daemon-executed names in install.sh's `DRIFTED`
    # list. It exists so the `deployedMatchesSource` assertions below can prove the field measures
    # the whole deployed surface rather than that 12-name subset (review finding, P2).
    printf 'cd v1\n' > "$PW/scripts/orchestrator-harness/check-port-drift.sh"
    $PG init -q >/dev/null 2>&1 && $PG add -A >/dev/null 2>&1 && $PG commit -qm base >/dev/null 2>&1
    deploy() { mkdir -p "$PO"; rm -f "$PO"/*.sh; cp "$PW"/scripts/orchestrator-harness/*.sh "$PO"/; }
    prov() { ( HERE="$PW/scripts/orchestrator-harness"; O="$PO"; HARNESS_REF=HEAD; . "$TMP/prov-block.sh" ); }
    dc()  { bash "$PC/check-deployed-drift.sh" --o "$PO" --repo "$PW" --ref HEAD --rel scripts/orchestrator-harness --no-fetch "$@" >/dev/null 2>&1; }
    dcm() { bash "$PC/check-deployed-drift.sh" --o "$PO" --repo "$PW" --ref HEAD --rel scripts/orchestrator-harness --no-fetch "$@" 2>&1; }
    deploy; prov
    PHEAD=$($PG rev-parse HEAD)
    grep -qF "\"commit\": \"$PHEAD\"" "$PO/.agent-infra-stamp.json" 2>/dev/null && rc=0 || rc=1
    ck "install.sh's provenance writer records the SOURCE commit (#1745)" $rc
    grep -qF '"relation": "current"' "$PO/.agent-infra-stamp.json" 2>/dev/null && rc=0 || rc=1
    ck "the stamp classifies the source as current at the ref" $rc
    grep -qE '"payloadSha256": "[0-9a-f]{64}"' "$PO/.agent-infra-stamp.json" 2>/dev/null && rc=0 || rc=1
    ck "the stamp records a payload hash over \$O/*.sh" $rc
    # #1837 review (P2): `install.sh` NEVER copies — the operator syncs `$O` — so the source commit
    # and the deployed bytes can genuinely disagree. Without a field saying so, the record reads as
    # "this commit describes these bytes" while the box runs other ones. Declared as a field, not
    # inferred from `relation` (which is git ancestry of the SOURCE, not a statement about `$O`).
    grep -qF '"deployedMatchesSource": true' "$PO/.agent-infra-stamp.json" 2>/dev/null && rc=0 || rc=1
    ck "the stamp says whether the deployed copy matches the source (in-sync: true)" $rc
    # `$O` that differs from the source: install.sh NEVER copies (`$O` is synced by the operator), so
    # an install run from a newer checkout can stamp a commit over bytes from an older one. Tampered
    # file is `check-port-drift.sh` — deliberately one NOT in install.sh's `DRIFTED` list, so this
    # assertion is RED if the field is derived from that subset instead of from the whole surface.
    printf 'tampered\n' > "$PO/check-port-drift.sh"
    prov
    grep -qF '"deployedMatchesSource": false' "$PO/.agent-infra-stamp.json" 2>/dev/null && rc=0 || rc=1
    ck "a \$O that differs from the source in a NON-DRIFTED script records deployedMatchesSource: false" $rc
    deploy; prov
    grep -qF '"deployedMatchesSource": true' "$PO/.agent-infra-stamp.json" 2>/dev/null && rc=0 || rc=1
    ck "re-recording an in-sync \$O restores deployedMatchesSource: true (the field is not sticky)" $rc
    # The OTHER direction, which a one-way `$HERE -> $O` comparison would miss: a hand-placed
    # `$O/*.sh` the repo does not ship is DRIFT to check-deployed-drift.sh, so the stamp must not
    # call that deployment a match either.
    printf 'hand-placed\n' > "$PO/legacy-probe.sh"
    prov
    grep -qF '"deployedMatchesSource": false' "$PO/.agent-infra-stamp.json" 2>/dev/null && rc=0 || rc=1
    ck "an extra \$O/*.sh the repo does not ship records deployedMatchesSource: false" $rc
    deploy; prov
    dc; rc=$?; [ "$rc" -eq 0 ] && rc=0 || { rc=1; echo "      matching deployment exited $rc"; }
    ck "check-deployed-drift: a matching deployment exits 0" $rc
    # a DIRTY source: its recorded commit cannot describe the deployed bytes
    printf 'dirty\n' >> "$PW/scripts/orchestrator-harness/orch-loop.sh"
    deploy; prov
    out="$(dcm)"; rc=$?
    [ "$rc" -eq 1 ] && case "$out" in *DIRTY*) rc=0;; *) rc=1;; esac || rc=1
    ck "check-deployed-drift: a DIRTY source record is drift, not a pass" $rc
    $PG checkout -q -- . >/dev/null 2>&1
    deploy; prov
    dc; rc=$?; [ "$rc" -eq 0 ] && rc=0 || rc=1
    ck "check-deployed-drift: re-recording a clean source restores the match" $rc
    # a POST-INSTALL hand edit to $O
    printf 'tampered\n' > "$PO/orch-loop.sh"
    dc; rc=$?; [ "$rc" -eq 1 ] && rc=0 || { rc=1; echo "      post-install edit exited $rc"; }
    ck "check-deployed-drift: a post-install edit to \$O exits 1" $rc
    deploy
    # the record is REQUIRED: absent -> UNKNOWN, never a pass
    mv "$PO/.agent-infra-stamp.json" "$TMP/prov-stamp.hold"
    dc; rc=$?; [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      missing record exited $rc"; }
    ck "check-deployed-drift: a MISSING record exits 2 (never a pass)" $rc
    mv "$TMP/prov-stamp.hold" "$PO/.agent-infra-stamp.json"
    # an explicit UNKNOWN commit is UNKNOWN too
    sed 's/"commit": "[0-9a-f]\{40\}"/"commit": "UNKNOWN"/' "$PO/.agent-infra-stamp.json" > "$TMP/prov-stamp.u"
    mv "$TMP/prov-stamp.u" "$PO/.agent-infra-stamp.json"
    dc; rc=$?; [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      commit UNKNOWN exited $rc"; }
    ck "check-deployed-drift: commit UNKNOWN exits 2 (never a pass)" $rc
    prov
    # an unresolvable ref is cannot-verify, not a match
    dc --ref no-such-ref; rc=$?; [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      bad ref exited $rc"; }
    ck "check-deployed-drift: an unresolvable ref exits 2, not 0" $rc
    # a recorded commit that is not an object in the repo is cannot-verify
    sed 's/"commit": "[0-9a-f]\{40\}"/"commit": "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef"/' "$PO/.agent-infra-stamp.json" > "$TMP/prov-stamp.d"
    mv "$TMP/prov-stamp.d" "$PO/.agent-infra-stamp.json"
    dc; rc=$?; [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      unknown commit object exited $rc"; }
    ck "check-deployed-drift: a recorded commit absent from the repo exits 2" $rc
    prov
    # the ref moves ahead -> behind is drift
    printf 'loop v2\n' > "$PW/scripts/orchestrator-harness/orch-loop.sh"
    $PG add -A >/dev/null 2>&1; $PG commit -qm advance >/dev/null 2>&1
    out="$(dcm)"; rc=$?
    [ "$rc" -eq 1 ] && case "$out" in *BEHIND*) rc=0;; *) rc=1;; esac || rc=1
    ck "check-deployed-drift: a ref that moved ahead exits 1 (behind is drift)" $rc
    deploy; prov
    dc; rc=$?; [ "$rc" -eq 0 ] && rc=0 || rc=1
    ck "check-deployed-drift: a fresh install at the new tip matches again" $rc
    # a repo-shipped file MISSING from $O
    rm -f "$PO/claims.sh"; prov
    out="$(dcm)"; rc=$?
    [ "$rc" -eq 1 ] && case "$out" in *MISSING*) rc=0;; *) rc=1;; esac || rc=1
    ck "check-deployed-drift: a repo-shipped file missing from \$O is drift" $rc
    # an EXTRA .sh in $O the repo does not ship
    deploy; prov; printf 'x\n' > "$PO/legacy.sh"
    out="$(dcm)"; rc=$?
    [ "$rc" -eq 1 ] && case "$out" in *"NOT shipped"*) rc=0;; *) rc=1;; esac || rc=1
    ck "check-deployed-drift: an extra hand-placed script in \$O is drift" $rc
    # a FAILING mktemp used to make the whole byte comparison silently skip and print OK (exit 0)
    deploy; prov
    MKB="$TMP/prov-nomk"; mkdir -p "$MKB"
    printf '#!/bin/bash\nexit 1\n' > "$MKB/mktemp"; chmod +x "$MKB/mktemp"
    PATH="$MKB:$PATH" bash "$PC/check-deployed-drift.sh" --o "$PO" --repo "$PW" --ref HEAD --rel scripts/orchestrator-harness --no-fetch >/dev/null 2>&1
    rc=$?; [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      failing mktemp exited $rc"; }
    ck "check-deployed-drift: a failed mktemp exits 2 (never a silent OK)" $rc
    # an UNREADABLE deployed *.sh is CANNOT-VERIFY, not a fabricated post-install hand edit
    deploy; prov; chmod 000 "$PO/claims.sh"
    dc; rc=$?; [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      unreadable deployed file exited $rc"; }
    ck "check-deployed-drift: an unreadable \$O/*.sh exits 2, not a false drift" $rc
    chmod 644 "$PO/claims.sh"
    # an EMPTY $O must not record the empty-input digest e3b0c442… as a payload
    EMPTYO="$TMP/prov-empty"; mkdir -p "$EMPTYO"
    ( HERE="$PW/scripts/orchestrator-harness"; O="$EMPTYO"; HARNESS_REF=HEAD; . "$TMP/prov-block.sh" )
    grep -q '"payloadSha256": "UNKNOWN"' "$EMPTYO/.agent-infra-stamp.json" 2>/dev/null && rc=0 || rc=1
    ck "install.sh's writer records UNKNOWN (not e3b0c442) for an empty \$O" $rc
    # ...and an empty $O carrying a REAL record is DRIFT (verifiable), not a crash
    deploy; prov; rm -f "$PO"/*.sh
    dc; rc=$?; [ "$rc" -eq 1 ] && rc=0 || { rc=1; echo "      empty deployed copy exited $rc"; }
    ck "check-deployed-drift: an empty \$O with a real record is DRIFT, not a crash" $rc
  else
    ck "deployed-drift: git is available to drive the check" 1
  fi
fi

# report.sh is an operator summary and MUST be safe to run while the loop is working: read-only,
# and every section degrades to a message rather than aborting when its surface is absent.
if [ -f "$HERE/report.sh" ]; then
  # ⛔ THE FIXTURE REPO MUST BE A GIT CHECKOUT, because report.sh now gets `REPO` from repo-slug.sh's
  # `resolve_repo`, which PROVES it is one (the same rule every other script had except this one, whose
  # `$HOME/eldato/tortoise` default meant nothing ever checked). A plain `mkdir` directory is exactly
  # what the resolver must refuse, so the fixture is a real (empty) repo.
  RO="$TMP/report-o"; RREPO="$TMP/report-repo"; mkdir -p "$RO/state" "$RO/logs" "$RREPO"; git init -q "$RREPO"
  printf '{ "version": 1, "surface": "laptop", "commit": "0123456789abcdef0123456789abcdef01234567", "relation": "current" }\n' > "$RO/.agent-infra-stamp.json"
  touch "$RO/state/merged-4242.done"
  printf '%s\treviewer\t7\t1800\t1790\t1\n' "$(date +%s)" > "$RO/state/walltime.tsv"
  printf 'now [dispatch] picked #1\n' > "$RO/logs/orch-loop.log"
  printf '1\n' > "$RO/candidates.txt"
  rout="$(O="$RO" REPO="$RREPO" bash "$HERE/report.sh" 24 2>&1)"; rrc=$?
  [ "$rrc" -eq 0 ] && rc=0 || { rc=1; echo "      report.sh exited $rrc"; }
  ck "report.sh runs read-only and exits 0 on a fixture" $rc
  # ⛔ THE WORKER COUNT IS NOT THE TMUX LIST (agent-infra#2210): on a cell every worker is a cmux
  # durable terminal, so `tmux ls | wc -l` printed 0 for a busy box — and `wt_table` prints ONE
  # newline for an EMPTY table, so a naive `wc -l` printed 1 for an idle one. An absent module must
  # read UNKNOWN, never 0: an operator who reads 0 concludes the box is idle.
  case "$rout" in
    *"sessions: UNKNOWN"*) rc=0 ;;
    *) rc=1; echo "      no 'sessions: UNKNOWN' line: $(printf '%s\n' "$rout" | grep -i sessions || echo '<absent>')" ;;
  esac
  ck "report.sh: no launcher module ⇒ sessions is UNKNOWN, not a confident 0" $rc
  mkdir -p "$RO/state"
  cat > "$RO/worker-terminal.sh" <<'SH'
#!/usr/bin/env bash
wt_table() { printf 'lane-1\talive\nfix-2\talive\n'; }
SH
  rout1="$(O="$RO" REPO="$RREPO" bash "$HERE/report.sh" 1 2>&1)"
  case "$rout1" in
    *"sessions: 2"*) rc=0 ;;
    *) rc=1; echo "      expected 'sessions: 2': $(printf '%s\n' "$rout1" | grep -i sessions || echo '<absent>')" ;;
  esac
  ck "report.sh: the count comes from the launcher's census (2 workers)" $rc
  cat > "$RO/worker-terminal.sh" <<'SH'
#!/usr/bin/env bash
# an IDLE daemon: the table function prints one blank line, which `wc -l` used to count as 1 worker
wt_table() { printf '\n'; }
SH
  rout0="$(O="$RO" REPO="$RREPO" bash "$HERE/report.sh" 1 2>&1)"
  case "$rout0" in
    *"sessions: 0"*) rc=0 ;;
    *) rc=1; echo "      an EMPTY table must be 0, not 1: $(printf '%s\n' "$rout0" | grep -i sessions || echo '<absent>')" ;;
  esac
  ck "report.sh: an EMPTY census is 0 workers, not 1 (the blank-line off-by-one)" $rc
  # ⛔ A DEAD ROW IS NOT A WORKER. The table keeps a record whose surface is gone until the reap clears
  # it; "sessions" answers "is this box busy", so a ledger entry must not inflate it.
  cat > "$RO/worker-terminal.sh" <<'SH'
#!/usr/bin/env bash
wt_table() { printf 'lane-1\talive\nfix-2\tdead\nmerge-3\tunknown\n'; }
SH
  routd="$(O="$RO" REPO="$RREPO" bash "$HERE/report.sh" 1 2>&1)"
  case "$routd" in
    *"sessions: 2"*) rc=0 ;;
    *) rc=1; echo "      alive+unknown must count, dead must not: $(printf '%s\n' "$routd" | grep -i sessions || echo '<absent>')" ;;
  esac
  ck "report.sh: a DEAD record is not counted as a session (unknown still is)" $rc
  printf '#!/usr/bin/env bash\nthis is not bash\n' > "$RO/worker-terminal.sh"
  routb="$(O="$RO" REPO="$RREPO" bash "$HERE/report.sh" 1 2>&1)"
  case "$routb" in
    *"sessions: UNKNOWN"*) rc=0 ;;
    *) rc=1; echo "      a module that cannot source must be UNKNOWN: $(printf '%s\n' "$routb" | grep -i sessions || echo '<absent>')" ;;
  esac
  ck "report.sh: a module that cannot source ⇒ UNKNOWN (never 0)" $rc
  rm -f "$RO/worker-terminal.sh"
  # ── the controller line is PLATFORM-BRANCHED: no launchctl on a cloud cell, so it must come from
  # the platform's OWN supervisor (`cloud-cell-supervisor.sh status`), never from a shrug; on macOS
  # the launchd branch must be the one taken. The SUPERVISOR_SH seam makes BOTH halves assertable on
  # any host. ⛔ NOTHING IS SKIPPED HERE ON PURPOSE: this suite's platform gate asserts that a Darwin
  # run runs every gated check (a skip there is a failure), and report.sh's launchd branch needs no
  # macOS to be identified — it simply must NOT consult the Linux supervisor.
  RS="$TMP/report-sup.sh"
  cat > "$RS" <<'SH'
#!/bin/bash
echo "controller: RUNNING (pid 4242) — SUPERVISOR-ANSWERED"
SH
  chmod +x "$RS"
  rout2="$(O="$RO" REPO="$RREPO" SUPERVISOR_SH="$RS" bash "$HERE/report.sh" 1 2>&1)"
  if on_darwin; then
    case "$rout2" in *"SUPERVISOR-ANSWERED"*) rc=1;; *) rc=0;; esac
    ck "report.sh takes the launchd branch on macOS (the Linux supervisor seam is not consulted)" $rc
  else
    case "$rout2" in *"SUPERVISOR-ANSWERED"*) rc=0;; *) rc=1;; esac
    ck "report.sh asks the platform supervisor on Linux (the controller line is not a shrug)" $rc
    # a supervisor that answers NOTHING is UNKNOWN — "could not verify" is never a state
    RS0="$TMP/report-sup-empty.sh"; printf '#!/bin/bash\nexit 0\n' > "$RS0"; chmod +x "$RS0"
    rout3="$(O="$RO" REPO="$RREPO" SUPERVISOR_SH="$RS0" bash "$HERE/report.sh" 1 2>&1)"
    case "$rout3" in *"UNKNOWN"*) rc=0;; *) rc=1;; esac
    ck "report.sh reports UNKNOWN when the supervisor prints nothing (cannot verify is not a pass)" $rc
  fi
  # ⛔ THE macOS CONTROLLER LINE MUST NAME THIS BOX'S ORCHESTRATOR — not any job whose LABEL merely
  # contains the substring (review P1). The arm was `awk '/orchestrator/{print $1}'`, so ANOTHER
  # repo's RUNNING job answered for this box: measured `UP (pid 999) heartbeat age: …` on a box whose
  # own job was LOADED with no process — a foreign pid dressed in THIS box's `$O/heartbeat`, and the
  # same fixture `bin/harness doctor` calls `supervisor: none`. Driven from ANY platform by stubbing
  # `uname` (the branch is selected by PLATFORM) and `launchctl`, and the POSITIVE control comes
  # FIRST so a stub that never reaches the arm cannot make the negative case pass vacuously.
  RB="$TMP/report-launchd"; mkdir -p "$RB"
  printf '#!/bin/bash\nprintf "Darwin\\n"\n' > "$RB/uname"; chmod +x "$RB/uname"
  mk_report_lc() { # <this box's pid> <another repo's pid>
    cat > "$RB/launchctl" <<LC
#!/bin/bash
[ "\$1" = list ] || exit 1
printf 'PID\tStatus\tLabel\n'
printf '%s\t0\tcom.apple.powerd\n' '-'
printf '%s\t0\tcom.eldato.orchestrator-loop\n' '$1'
printf '%s\t0\tcom.tortoise.orchestrator-loop\n' '$2'
exit 0
LC
    chmod +x "$RB/launchctl"
  }
  mk_report_lc 4242 '-'
  rout4="$(PATH="$RB:$PATH" O="$RO" REPO="$RREPO" bash "$HERE/report.sh" 1 2>&1)"
  case "$rout4" in *"UP (pid 4242)"*) rc=0;; *) rc=1;; esac
  ck "report.sh reads THIS box's own launchd job as UP when it is RUNNING (control)" $rc
  mk_report_lc '-' 4243
  rout5="$(PATH="$RB:$PATH" O="$RO" REPO="$RREPO" bash "$HERE/report.sh" 1 2>&1)"
  case "$rout5" in
    *"pid 4243"*|*"UP ("*) rc=1 ;;
    *"NOT RUNNING"*) rc=0 ;;
    *) rc=1 ;;
  esac
  [ "$rc" -eq 0 ] || echo "      $(printf '%s' "$rout5" | tr '\n' '|')"
  ck "report.sh: ANOTHER repo's orchestrator job is never this box's controller (no false UP)" $rc
  # ⛔ TWO COPIES OF ONE ANCHORED PATTERN, SO ASSERT THEY AGREE. `HARNESS_UNIT_RE` is duplicated on
  # purpose (bin/harness ships from bin/, these scripts ship to $O, so a sourced file would not reach
  # both) — which means it can DRIFT, and a loosening on one side would silently reopen the very
  # attribution defect both comments cite. Byte equality is cheap to assert and impossible to forget.
  if [ -f "$HERE/../../bin/harness" ]; then
    pat_of() { sed -n "s/^[[:space:]]*HARNESS_UNIT_RE='\\(.*\\)'[[:space:]]*$/\\1/p" "$1" | head -1; }
    rpat="$(pat_of "$HERE/report.sh")"; hpat="$(pat_of "$HERE/../../bin/harness")"
    [ -n "$rpat" ] && [ "$rpat" = "$hpat" ] && rc=0 || { rc=1; echo "      report.sh=[$rpat] bin/harness=[$hpat]"; }
    ck "report.sh and bin/harness match the launchd label on the SAME anchored pattern (no drift)" $rc
  fi
  case "$rout" in *"orchestrator report"*) rc=0;; *) rc=1;; esac
  ck "report.sh prints the window header" $rc
  # A leading-zero HOURS arg is OCTAL to `$(( ))`. Measured pre-fix: `report.sh 08` printed
  # "08: value too great for base" at the `FROM=` line and then died at the first use of `$FROM`
  # ("FROM: unbound variable", rc=1), stopping the report partway. It must clamp to the 12h
  # default instead.
  rout08="$(O="$RO" REPO="$RREPO" bash "$HERE/report.sh" 08 2>&1)"; rrc08=$?
  [ "$rrc08" -eq 0 ] && case "$rout08" in *"orchestrator report"*"12h"*) rc=0;; *) rc=1;; esac || rc=1
  ck "report.sh clamps a leading-zero HOURS arg instead of dying in the arithmetic" $rc
  case "$rout" in *"total in window: 1"*) rc=0;; *) rc=1;; esac
  ck "report.sh counts merges in the window (the count is not lost to a subshell)" $rc
  case "$rout" in *"agent wall-time"*) rc=0;; *) rc=1;; esac
  ck "report.sh reports per-kind agent wall-time" $rc
  case "$rout" in *"harness: 0123456789ab"*) rc=0;; *) rc=1;; esac
  ck "report.sh reports which harness commit the box runs (#1745)" $rc
  # the report must degrade silently when the queue files do not exist (`wc -l < missing` prints a
  # bash REDIRECTION error that `wc ... 2>/dev/null` cannot suppress)
  rm -f "$RO/candidates.txt" "$RO/dispatched.txt"
  rerr="$(O="$RO" REPO="$RREPO" bash "$HERE/report.sh" 24 2>&1 >/dev/null)"
  case "$rerr" in *"No such file"*) rc=1;; *) rc=0;; esac
  ck "report.sh degrades silently when the queue files are absent" $rc
else
  ck "report.sh is shipped" 1
fi

# ── bin/harness: the harness's own `doctor` CLI ─────────────────────────────────────────────────
# ⛔ THIS GROUP EXISTS BECAUSE `bin/harness` HAD NO COVERAGE AT ALL (review P2, this round): every other
# shipped script is exercised here (`report.sh`, `merge-one.sh`'s extracted functions,
# `check-port-drift.sh`, `merged-not-closed.sh`), and `bin/harness` — 400+ new lines that answer "which
# platform, which supervisor, which commit, has any copy forked" — was covered only by a CI step that
# asserted KEY PRESENCE with `|| true`. Three reproducible fail-opens shipped through that gap (a fork
# path silently rewritten so a spaced path read `ok`; a canonical copy missing a file reported as
# `FORK PRESENT`; `--json` unparseable when a configured path held a quote). The checks that name one
# of those three fail-opens are RED on the code before the round that fixed it, so they are regression
# guards rather than smoke tests; two arms here (`rc` agrees with the published verdict, a regular FILE
# at `$O` is unknown) predate the round and would pass both ways — they guard a LATER revert, not the
# fix, and are here because nothing else drove them at all.
HARNESS="$HERE/../../bin/harness"
if [ -f "$HARNESS" ]; then
  HL="$TMP/harness-o"; mkdir -p "$HL"
  hout="$(O="$HL/absent" "$HARNESS" doctor --json 2>&1)"; hrc=$?
  hj=0
  printf '%s' "$hout" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["verdict"] in ("OK","DRIFT","UNKNOWN"), d; assert d["deployed"]["kind"]=="absent", d["deployed"]; assert d["forksChecked"] is False, d' 2>/dev/null || hj=1
  ck "bin/harness doctor --json parses, and says forksChecked=false when no path was configured" $hj
  hv="$(printf '%s' "$hout" | sed -n 's/.*"verdict": "\([A-Z]*\)".*/\1/p' | head -1)"
  case "$hv" in OK) hwant=0 ;; DRIFT) hwant=1 ;; UNKNOWN) hwant=2 ;; *) hwant=9 ;; esac
  [ "$hwant" = "$hrc" ] && rc=0 || { rc=1; echo "      verdict=$hv rc=$hrc"; }
  ck "bin/harness doctor's exit code agrees with the verdict it published (0/1/2)" $rc
  # ⛔ A PATH WITH A SPACE MUST BE CHECKED, NOT REWRITTEN. The arm trimmed with `tr -d '[:space:]'`,
  # which deletes INTERNAL whitespace: `/tmp/x/fork dir` became `/tmp/x/forkdir`, a directory that does
  # not exist, and the arm then printed `ok` for it. Re-measured RED on the pre-fix code.
  HF="$TMP/fork dir"; mkdir -p "$HF"; cp "$HERE/lane.sh" "$HF/lane.sh"
  HARNESS_FORK_PATHS="$HF" O="$HL/absent" "$HARNESS" doctor --json > "$TMP/h-fork.json" 2>/dev/null
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["forks"]=="FORK PRESENT", d["forks"]' "$TMP/h-fork.json" 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor FINDS a fork at a path containing a space (the path is not rewritten)" $rc
  # ⛔ AND rc 1 FROM THE CHECKER IS NOT SYNONYMOUS WITH A FORK. The checker's canonical-completeness arm
  # also exits 1, so a canonical copy missing a shared file reached the fork arm as "a fork" and sent an
  # operator to hunt a location that held nothing (measured: `claims.sh` removed, `--fork` dir empty).
  HT="$TMP/harness-broken"; mkdir -p "$HT/bin" "$HT/scripts" "$TMP/harness-nofork"
  cp "$HARNESS" "$HT/bin/harness"; cp -a "$HERE" "$HT/scripts/orchestrator-harness"
  rm -f "$HT/scripts/orchestrator-harness/claims.sh"
  HARNESS_FORK_PATHS="$TMP/harness-nofork" O="$HL/absent" "$HT/bin/harness" doctor --json > "$TMP/h-can.json" 2>/dev/null
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["forks"]=="CANONICAL INCOMPLETE", d["forks"]' "$TMP/h-can.json" 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor names a MISSING canonical file instead of claiming FORK PRESENT" $rc
  # ⛔ A QUOTE IN A CONFIGURED PATH IS LEGAL AND MUST NOT BREAK THE MACHINE SURFACE. The JSON heredoc
  # interpolated raw, so `O=/tmp/q"dir` produced `"path": "/tmp/q"dir"` and `json.loads` threw.
  HQ="$TMP/q\"dir"; mkdir -p "$HQ"
  O="$HQ" "$HARNESS" doctor --json > "$TMP/h-quote.json" 2>/dev/null
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/h-quote.json" 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor --json stays parseable when a path contains a quote" $rc
  # ⛔ A CARRIAGE RETURN IS A CONTROL BYTE JSON FORBIDS RAW (review P2, round 3): the delete stage
  # omitted `\015`, so a CR passed through unescaped and `json.loads` threw
  # "Invalid control character". `\n` and `\t` were already collapsed to spaces; CR now joins them.
  crO="$(printf '/tmp/x/cr\rhere')"
  O="$crO" "$HARNESS" doctor --json > "$TMP/h-cr.json" 2>/dev/null
  python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$TMP/h-cr.json" 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor --json stays parseable when a path contains a carriage return" $rc
  # ⛔ AND WHEN IT HOLDS A BYTE THAT IS NOT VALID UTF-8 (review P2, round 4): legal on Linux (any byte
  # but `/` and NUL). Passing it through made the whole document UNDECODABLE — `json.loads` could not
  # even reach the parser (`UnicodeDecodeError`).
  hxO="$(printf '/tmp/x/\377o')"
  O="$hxO" "$HARNESS" doctor --json > "$TMP/h-nonutf8.json" 2>/dev/null
  python3 -c 'import json,sys; json.load(open(sys.argv[1], encoding="utf-8"))' "$TMP/h-nonutf8.json" 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor --json stays decodable when a path holds a non-UTF-8 byte" $rc
  # ⛔ AND IT IS OMITTED, NOT MANGLED INTO ANOTHER REAL PATH (review P2, round 5): `iconv -c` DELETED the
  # byte, so `/tmp/k/\xffx` (a real directory) came back as `/tmp/k/x` — a DIFFERENT real directory, and
  # a consumer shown that JSON inspects the wrong tree. The value must say it is unrepresentable.
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); p=d["deployed"]["path"]; assert "not representable" in p, p' "$TMP/h-nonutf8.json" 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor --json OMITS a non-UTF-8 path instead of deleting the byte into another path" $rc
  # An existing NON-DIRECTORY at $O is not "nothing deployed" — the whole deployed section is gated on
  # `-d`, so this used to keep the `absent` initialiser and report a healthy box about a path it could
  # not read.
  : > "$TMP/harness-o-file"
  O="$TMP/harness-o-file" "$HARNESS" doctor --json > "$TMP/h-file.json" 2>/dev/null
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["deployed"]["kind"]=="unreadable", d["deployed"]; assert d["unknown"] >= 1, d' "$TMP/h-file.json" 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor: \$O that is a regular FILE is unknown, never 'absent'" $rc
  # ⛔ THE SUPERVISOR-ATTRIBUTION FIX NEEDS A DISCRIMINATING CHECK (review P2, re-review round): it was
  # the round's headline P2 and nothing drove it, so the anchoring could be reverted with both CI
  # lanes green. Driven from ANY platform by stubbing `uname` (the arm is selected by PLATFORM) and
  # `launchctl` — and the POSITIVE control comes FIRST, so a stub that never reaches the arm cannot
  # make the negative case pass vacuously.
  mkdir -p "$TMP/lstub"
  printf '#!/bin/bash\nprintf "Darwin\\n"\n' > "$TMP/lstub/uname"; chmod +x "$TMP/lstub/uname"
  mk_launchctl() { # <dst> <label> <pid>
    cat > "$1" <<LC
#!/bin/bash
[ "\$1" = list ] || exit 1
printf 'PID\tStatus\tLabel\n'
printf '%s\t0\tcom.apple.powerd\n' '-'
printf '%s\t0\t%s\n' '$3' '$2'
exit 0
LC
    chmod +x "$1"
  }
  mk_launchctl "$TMP/lstub/launchctl" com.eldato.orchestrator-loop 4242
  hout2="$(PATH="$TMP/lstub:$PATH" O="$HL/absent" "$HARNESS" doctor --json 2>/dev/null)"
  printf '%s' "$hout2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["supervisor"]=="launchd", d["supervisor"]' 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor: this box's OWN launchd label is accepted as the supervisor (control)" $rc
  mk_launchctl "$TMP/lstub/launchctl" com.tortoise.orchestrator-loop 4243
  hout2="$(PATH="$TMP/lstub:$PATH" O="$HL/absent" "$HARNESS" doctor --json 2>/dev/null)"
  printf '%s' "$hout2" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d["supervisor"]!="launchd", d["supervisor"]' 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor: ANOTHER repo's orchestrator label is NOT this box's supervisor" $rc
  # ⛔ BOTH DEFECTS AT ONCE NAME BOTH (review P2, round 3): a reappeared fork used to MASK an
  # incomplete canonical copy, so the missing file went unnamed and was discoverable only by deleting
  # the fork and re-running. Driven through `doctor` in a fixture tree (CANON is resolved from the
  # harness's own location, so the fixture needs both bin/harness and its scripts dir).
  rm -rf "$TMP/both"; mkdir -p "$TMP/both/repo/bin" "$TMP/both/repo/scripts" "$TMP/both/forkt"
  cp -a "$HERE" "$TMP/both/repo/scripts/orchestrator-harness"
  cp "$HARNESS" "$TMP/both/repo/bin/harness"; chmod +x "$TMP/both/repo/bin/harness"
  rm -f "$TMP/both/repo/scripts/orchestrator-harness/claims.sh"
  printf '#!/bin/bash\n' > "$TMP/both/forkt/orch-loop.sh"
  hout3="$(HARNESS_FORK_PATHS="$TMP/both/forkt" O="$TMP/both/absent" "$TMP/both/repo/bin/harness" doctor --json 2>/dev/null)"
  printf '%s' "$hout3" | python3 -c 'import json,sys; d=json.load(sys.stdin); f=d["forks"]; assert "FORK PRESENT" in f, f; assert "CANONICAL INCOMPLETE" in f, f' 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor: a fork AND an incomplete canonical copy are BOTH named in one answer" $rc
  rm -rf "$TMP/both"
  # ⛔ AND THE MARKER IS READ FROM THE CHECKER'S CAUSE LINE, NEVER FROM ITS ECHO OF THE PATH (review P2,
  # round 5): the checker prints `ok: <the fork path> holds none of the …` on stdout, so a DIRECTORY
  # NAMED `retired fork has reappeared` authored the claim itself — measured, an empty dir of that name
  # plus one real canonical miss reported `FORK PRESENT + CANONICAL INCOMPLETE` (drift=2) about a
  # location the same output says holds no fork.
  rm -rf "$TMP/nameit"; mkdir -p "$TMP/nameit/repo/bin" "$TMP/nameit/repo/scripts" "$TMP/nameit/retired fork has reappeared"
  cp -a "$HERE" "$TMP/nameit/repo/scripts/orchestrator-harness"
  cp "$HARNESS" "$TMP/nameit/repo/bin/harness"; chmod +x "$TMP/nameit/repo/bin/harness"
  rm -f "$TMP/nameit/repo/scripts/orchestrator-harness/claims.sh"
  # a file the arm does not look for, so the target is a real COMPARISON (an empty dir is its own
  # "not a comparison" arm at rc 2) — and the `ok:` line echoing the path is exactly what used to
  # author the claim
  printf 'x\n' > "$TMP/nameit/retired fork has reappeared/notes.txt"
  hout5="$(HARNESS_FORK_PATHS="$TMP/nameit/retired fork has reappeared" O="$TMP/nameit/absent" "$TMP/nameit/repo/bin/harness" doctor --json 2>/dev/null)"
  printf '%s' "$hout5" | python3 -c 'import json,sys; d=json.load(sys.stdin); f=d["forks"]; assert "FORK PRESENT" not in f, f; assert "CANONICAL INCOMPLETE" in f, f' 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor: a fork PATH named like a cause cannot author the claim (markers are anchored)" $rc
  rm -rf "$TMP/nameit"
  # ⛔ A CHECKER THAT COULD NOT RUN IS NOT A CLAIM ABOUT THE CANONICAL COPY (review P2, round 4): the
  # catch-all arm answered "CANONICAL INCOMPLETE" for any rc other than 0/2 — so rc 127 (a noexec
  # mount, a broken interpreter) or 137 produced a confident "a shared file is missing from the source
  # of truth" about a copy nobody had read, with `forksChecked: true` beside it.
  rm -rf "$TMP/deadck"; mkdir -p "$TMP/deadck/repo/bin" "$TMP/deadck/repo/scripts" "$TMP/deadck/fork"
  cp -a "$HERE" "$TMP/deadck/repo/scripts/orchestrator-harness"
  cp "$HARNESS" "$TMP/deadck/repo/bin/harness"; chmod +x "$TMP/deadck/repo/bin/harness"
  printf '#!/bin/bash\necho boom >&2\nexit 127\n' > "$TMP/deadck/repo/scripts/orchestrator-harness/check-single-source.sh"
  chmod +x "$TMP/deadck/repo/scripts/orchestrator-harness/check-single-source.sh"
  hout4="$(HARNESS_FORK_PATHS="$TMP/deadck/fork" O="$TMP/deadck/absent" "$TMP/deadck/repo/bin/harness" doctor --json 2>/dev/null)"
  printf '%s' "$hout4" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert "UNVERIFIABLE" in d["forks"], d["forks"]; assert d["forksChecked"] is False, d["forksChecked"]' 2>/dev/null && rc=0 || rc=1
  ck "bin/harness doctor: a checker that could not run (rc 127) is UNVERIFIABLE, not CANONICAL INCOMPLETE" $rc
  rm -rf "$TMP/deadck"
  rm -rf "$TMP/lstub"
else
  ck "bin/harness is shipped" 1
fi

# ── check-single-source.sh: the anti-relapse gate's OWN arms ──────────────────────────────────────
# ⛔ THE GATE'S FAIL-CLOSED ARMS HAD NO TEST (review P2, this round). The CI workflow drives three of
# them (fork present, byte divergence, nothing-to-check) and nothing drove the rest — so the arms this
# file argues for across eleven review cycles (`_resolve_state`'s dangling/unreadable/non-directory
# states, the two self-comparison guards, the EXECUTED-presence arm) could be deleted with CI green.
# That is the false-PASS shape `selftest.sh` exists to catch, in the one instrument this PR adds.
CSS="$HERE/check-single-source.sh"
if [ -f "$CSS" ]; then
  CSD="$TMP/css"; mkdir -p "$CSD/good"
  for f in "$HERE"/*.sh; do [ -f "$f" ] && cp "$f" "$CSD/good/"; done
  bash "$CSS" --require-target --o "$CSD/good" >/dev/null 2>&1
  ck "check-single-source: an identical deployed copy passes" $?
  printf '%s\n' '# drift' >> "$CSD/good/spawn-gate.sh"
  bash "$CSS" --o "$CSD/good" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && rc=0 || { rc=1; echo "      byte-divergent copy exited $rc"; }
  ck "check-single-source: a ONE-BYTE divergence is refused (rc 1)" $rc
  # ⛔ THE WIDENING ITSELF (review P2, re-review round): every fixture here copied only `*.sh`, so
  # restoring `for f in "$HERE"/*.sh` left this whole block green — which is exactly how the
  # `gh-limit/gh` gap survived the round that widened the set. One full-PAYLOAD copy, then one append
  # per shipped non-`.sh` file, each restored afterwards.
  mkdir -p "$CSD/payload"; cp -a "$HERE"/. "$CSD/payload"/
  bash "$CSS" --require-target --o "$CSD/payload" >/dev/null 2>&1
  ck "check-single-source: a full PAYLOAD copy (non-.sh included) is identical" $?
  for _nf in gh-limit.py gh-rest/gh gh-limit/gh; do
    printf '\n# STALE\n' >> "$CSD/payload/$_nf"
    bash "$CSS" --o "$CSD/payload" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 1 ] && rc=0 || { rc=1; echo "      a divergence in $_nf exited $rc (is the *.sh glob back?)"; }
    ck "check-single-source: a divergence in the shipped non-.sh file $_nf is refused (rc 1)" $rc
    cp "$HERE/$_nf" "$CSD/payload/$_nf"
  done
  rm -rf "$CSD/payload"
  # ⛔ A SHIPPED NAME WITH WHITESPACE IS STILL A SHIPPED FILE (review P2, round 4): `DEPLOY_SET` was a
  # whitespace-joined STRING, so `hotfix 2.sh` split into two tokens that name nothing and a DIVERGING
  # copy reported "ok: one source of truth" (measured rc 0 with a live control at rc 1).
  rm -rf "$TMP/spc"; mkdir -p "$TMP/spc/h" "$TMP/spc/o"
  cp -a "$HERE"/. "$TMP/spc/h"/; cp -a "$HERE"/. "$TMP/spc/o"/
  printf 'x\n' > "$TMP/spc/h/hotfix 2.sh"; printf 'x\n' > "$TMP/spc/o/hotfix 2.sh"
  printf '# drift\n' >> "$TMP/spc/o/hotfix 2.sh"
  bash "$TMP/spc/h/check-single-source.sh" --o "$TMP/spc/o" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && rc=0 || { rc=1; echo "      a divergence in a SPACE-BEARING file name exited $rc — the set is being word-split again"; }
  ck "check-single-source: a divergence in a shipped file whose NAME holds a space is refused (rc 1)" $rc
  rm -rf "$TMP/spc"
  mkdir -p "$CSD/execmissing"
  for f in "$HERE"/*.sh; do
    [ -f "$f" ] || continue
    [ "$(basename "$f")" = "merged-not-closed.sh" ] && continue
    cp "$f" "$CSD/execmissing/"
  done
  bash "$CSS" --o "$CSD/execmissing" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 1 ] && rc=0 || { rc=1; echo "      a deployed copy missing an EXECUTED file exited $rc"; }
  ck "check-single-source: the EXECUTED presence arm refuses a copy missing one" $rc
  env -u O bash "$CSS" --require-target --quiet >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      --require-target with nothing to compare exited $rc"; }
  ck "check-single-source: --require-target with nothing to compare is UNKNOWN (rc 2)" $rc
  mkdir -p "$CSD/emptyfork"
  env -u O bash "$CSS" --require-target --fork "$CSD/emptyfork" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      an empty --fork dir exited $rc"; }
  ck "check-single-source: an EXISTING-BUT-EMPTY --fork dir is not a comparison (rc 2)" $rc
  ln -sfn "$CSD/nope" "$CSD/dangle"
  bash "$CSS" --o "$CSD/dangle" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      a dangling --o exited $rc"; }
  ck "check-single-source: a DANGLING --o is not 'nothing deployed' (rc 2)" $rc
  : > "$CSD/afile"
  bash "$CSS" --o "$CSD/afile" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      a regular-file --o exited $rc"; }
  ck "check-single-source: --o that is a regular FILE is UNKNOWN (rc 2)" $rc
  bash "$CSS" --o "$HERE" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      --o == canonical exited $rc"; }
  ck "check-single-source: comparing canonical with ITSELF is refused (rc 2)" $rc
  bash "$CSS" --fork "$HERE" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      --fork == canonical exited $rc"; }
  ck "check-single-source: a --fork target that IS canonical is refused (rc 2)" $rc
  if [ "$(id -u)" = "0" ]; then
    # root ignores the mode bits, so the arm cannot be driven here. Skipped LOUDLY, never counted as a pass.
    skipd "check-single-source: an unsearchable --o / --fork is UNKNOWN (mode 000 is unenforceable as root)"
  else
    mkdir -p "$CSD/noread"; chmod 000 "$CSD/noread"
    bash "$CSS" --o "$CSD/noread" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      an unsearchable --o exited $rc"; }
    ck "check-single-source: an UNSEARCHABLE --o is UNKNOWN, not 'missing files' (rc 2)" $rc
    bash "$CSS" --fork "$CSD/noread" >/dev/null 2>&1; rc=$?
    [ "$rc" -eq 2 ] && rc=0 || { rc=1; echo "      an unsearchable --fork exited $rc"; }
    ck "check-single-source: an UNSEARCHABLE --fork cannot report 'no fork' (rc 2)" $rc
    chmod 755 "$CSD/noread"
  fi
  # ⛔ THE FOURTH INSTRUMENT'S OWN ARM — `REPO` IS SET ONCE PER BOX (this PR). A per-script REPO path
  # default is the same defect as a forked directory one variable over, and before this arm NOTHING
  # reddened for it: three shipped scripts carried `$HOME/…`, `/tmp/cell-ai` and `$PWD` respectively.
  # Both directions in a THROWAWAY copy of the harness, so the repo is never mutated.
  rm -rf "$TMP/rpdef"; mkdir -p "$TMP/rpdef/h"
  cp -a "$HERE"/. "$TMP/rpdef/h"/
  # A COMMENT mentioning a default must not red (prose is how the defect is recorded), the assignment
  # on the next line must.
  printf '#!/bin/bash\n# REPO="${REPO:-/some/path}" is the shape this arm forbids\nREPO="$HOME/x"\n' > "$TMP/rpdef/h/zz-holdout.sh"
  # ⛔ `env -u O` ON BOTH ARMS (#3054 review, P2). Without it the throwaway run inherits the ambient
  # `$O`, so on any box whose deployed copy differs from this checkout — i.e. every box mid-change —
  # the run exits 1 from the DEPLOYED-COPY divergence arms and the "allowed shapes" arm below blames
  # the REPO arm for it. It was green only in CI, where `$O` is absent, so it proved the shapes are
  # allowed nowhere that matters. `check-single-source.sh` reads `O_DIR="${O:-}"`, so unsetting it
  # narrows the run to the half under test instead of inventing a target.
  out="$(env -u O bash "$TMP/rpdef/h/check-single-source.sh" 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -q 'zz-holdout.sh:3' <<<"$out"; } && rc=0 \
    || { rc=1; echo "      a private REPO path default exited $rc: $(printf '%s\n' "$out" | grep -i 'PRIVATE' || echo '<not named>') (a comment mentioning one must NOT be the hit: the reported line is the assignment's)"; }
  ck "check-single-source: a private REPO path default is refused, naming file AND line (rc 1)" $rc
  # ⛔ A DEFAULT SPELLED AS ANOTHER VARIABLE IS THE SAME DEFECT, ONE INDIRECTION OVER (#3054 review,
  # P1). `pathish` only recognised `$HOME`/`$PWD`/a literal path, and `allowed_default` (which catches
  # `$AI`, `$CELL_HOME/x`, `$(pwd)`) was reached ONLY inside the `${REPO:-…}` branch — so measured at
  # 637c21c19 these two passed GREEN over a live private default. Both spellings are fixtures here;
  # `$AI` is not a made-up name: it is deploy-crossbox.sh's old default one variable over.
  for _aspell in '$AI' '$(pwd)' '${CELL_HOME:-}/tortoise'; do
    printf '#!/bin/bash\nREPO="%s"\n' "$_aspell" > "$TMP/rpdef/h/zz-holdout.sh"
    out="$(env -u O bash "$TMP/rpdef/h/check-single-source.sh" 2>&1)"; rc=$?
    { [ "$rc" -eq 1 ] && grep -q 'zz-holdout.sh:2' <<<"$out"; } && rc=0 \
      || { rc=1; echo "      REPO=\"$_aspell\" exited $rc: $(printf '%s\n' "$out" | grep -i 'PRIVATE' || echo '<not named>')"; }
    ck "check-single-source: a private REPO default spelled REPO=\"$_aspell\" is refused" $rc
  done
  # Non-vacuity in the other direction: the shapes the whole harness is converging ON must not red.
  # ⛔ THE CARVE-OUTS ARE PINNED HERE (#3054 review, P1), because the rule that catches `$AI` can
  # over-reach: a value THIS FILE holds (`$L_DIR`, and a substitution derived from a `for` variable)
  # is something the script MEASURED, and a SLUG — literal or defaulted — is not a checkout path at
  # all. If a later widening starts reddening these, it reds the shipped tree instead.
  {
    printf '#!/bin/bash\n'
    printf 'REPO="${REPO:-}"\n'
    printf 'REPO="$1"\n'
    printf 'REPO="$(resolve_repo)"\n'
    printf 'REPO="${HARNESS_REPO:-${HARNESS_APPLY_REPO:-}}"\n'   # a nested EMPTY default supplies nothing
    printf 'REPO="$REPO"\nREPO="${REPO:?REPO is required}"\n'      # the operator's OWN value, re-asserted
    printf 'REPO="${FLEET_REPO:-daniel-ospina/agent-infra}"\n'      # a SLUG default
    printf 'REPO="daniel-ospina/agent-infra"\n'                       # a SLUG literal
    printf 'L_DIR="/tmp/x"\nREPO="$L_DIR"\n'                        # a value THIS FILE holds
    printf 'for cand in /tmp\ndo\n  REPO="$(cd "$cand" && pwd -P)"\ndone\n'
  } > "$TMP/rpdef/h/zz-holdout.sh"
  out="$(env -u O bash "$TMP/rpdef/h/check-single-source.sh" 2>&1)"; rc=$?
  [ "$rc" -eq 0 ] && rc=0 \
    || { rc=1; echo "      the ALLOWED shapes (no default / assigned from a caller / the one resolver / an empty default / the operator's own value / a slug / a value this file holds) exited $rc: $(printf '%s\n' "$out" | grep -i 'PRIVATE' | head -3)"; }
  ck "check-single-source: REPO=\"\${REPO:-}\", a caller-assigned REPO, resolve_repo, an EMPTY default, a SLUG and a value THIS FILE holds all pass" $rc
  # ⛔ THE POPULATION IS TWO DIRECTORIES, AND THIS ARM PINS IT (verification finding, P1). The scan was
  # `$HERE/*.sh` only, so two of the three offenders this arm was written for — `pi-reap-worktrees.sh`
  # and `deploy-crossbox.sh`, both in the repo's `scripts/` — sat OUTSIDE it: measured, putting
  # `REPO="${REPO:-$PWD}"` back into the reaper reddened nothing. The fixture is the repo's OWN layout
  # (`scripts/` containing `orchestrator-harness/`), so a narrowing back to one directory reds here.
  # ⛔ AND THE PATH CONTAINS A SPACE ON PURPOSE (round 2): the parent path was expanded UNQUOTED in the
  # population loop, so under a space-bearing checkout the `scripts/` half was never scanned and the gate
  # exited 0 OVER this exact fixture, printing "nothing to scan there". `$TMP` never holds a space, so
  # without this the regression is invisible — and macOS space-bearing paths are ordinary.
  mkdir -p "$TMP/rpdef/repo scripts"
  cp -a "$HERE"/. "$TMP/rpdef/repo scripts/orchestrator-harness"/
  cp "$HERE/../pi-reap-worktrees.sh" "$TMP/rpdef/repo scripts/pi-reap-worktrees.sh"
  printf 'REPO="${REPO:-$PWD}"\n' >> "$TMP/rpdef/repo scripts/pi-reap-worktrees.sh"
  out="$(bash "$TMP/rpdef/repo scripts/orchestrator-harness/check-single-source.sh" 2>&1)"; rc=$?
  { [ "$rc" -eq 1 ] && grep -q 'pi-reap-worktrees.sh:[0-9]' <<<"$out"; } && rc=0 \
    || { rc=1; echo "      a default in scripts/ (the reaper) exited $rc: $(printf '%s\n' "$out" | grep -iE 'PRIVATE|nothing to scan' || echo '<not named>') — the arm is scanning ONE directory again (or word-split the parent path)"; }
  ck "check-single-source: a REPO path default in scripts/*.sh (not just the harness dir) is refused" $rc
  # ⛔ THE SPELLING WAS A WAY AROUND THE ARM (#3054 review, P2). `pathish` matched the LITERAL `$HOME`
  # and `$PWD`, so writing the exact default this PR removes ONE BRACE AWAY — `${HOME}/eldato/tortoise`,
  # `${PWD}` — passed the gate untouched: the "a PR or an agent can defeat it" class. Both spellings are
  # fixtures here, in the same throwaway copy, so a rewrite back to a bare-only match reds.
  for _bshape in '${HOME}/eldato/tortoise' '${PWD}'; do
    printf '#!/bin/bash\nREPO="${REPO:-%s}"\n' "$_bshape" > "$TMP/rpdef/repo scripts/pi-reap-worktrees.sh"
    out="$(bash "$TMP/rpdef/repo scripts/orchestrator-harness/check-single-source.sh" 2>&1)"; rc=$?
    { [ "$rc" -eq 1 ] && grep -q 'pi-reap-worktrees.sh:[0-9]' <<<"$out"; } && rc=0 \
      || { rc=1; echo "      the brace spelling $_bshape exited $rc: $(printf '%s\n' "$out" | grep -i 'PRIVATE' || echo '<not named>') — pathish matches only the BARE \$HOME/\$PWD"; }
    ck "check-single-source: the brace spelling REPO=\"\${REPO:-$_bshape}\" is refused too" $rc
  done
  rm -rf "$TMP/rpdef"
else
  ck "check-single-source.sh is shipped" 1
fi

echo
# ── P) the no-search bound: present in every agent prompt, and its heredoc does not EXECUTE backticks ──
# The three agent prompts are built by UNQUOTED heredocs (`cat > file <<EOF`), so a BARE backtick in
# the prompt text is command substitution at prompt-build time. An earlier draft of this fix would
# have run `uv sync` and spliced its output into the reviewer prompt, and erased the literal
# `UNVERIFIED` — and `bash -n` does NOT catch it (the script is syntactically valid; the bug is what
# the shell DOES with it).
#
# TWO checks, because each is blind to a class the other covers (agent-infra#1835 review, P2: with
# only the execution check, a bare `git add -A` PASSED here while git really ran, because `git` had
# never been added to the stub list):
#   (1) TEXTUAL and NAME-BLIND — in each prompt heredoc, count backticks against backslash-escaped
#       backticks; a bare one makes them differ. This also covers a command that CANNOT be stubbed
#       (`-maxdepth` -> "command not found"): it executes, erases prompt text, and an execution-only
#       rig sees an EMPTY tripwire.
#   (2) EXECUTION — expand each shipped heredoc with a stub for every command its backtick spans
#       name, so a bare backtick's command writes to a tripwire file. This exercises the real
#       expansion path, and catches a command whose output happens to equal the literal it replaced.
# The last blocks are NON-VACUITY controls: the execution rig against a deliberately unescaped
# heredoc (a STUBBED command, and the `git` class that passed before this fix), and the textual
# check against a name no stub can intercept. A rig that cannot fire proves nothing.
NB="$TMP/nb"; mkdir -p "$NB/bin" "$NB/repo/.venv/bin" "$NB/o/logs"
: > "$NB/trip"
# The population is every first-word that appears in a backtick span of the three prompts — the
# spans name uv/find/rg/du/mdfind/ls/UNVERIFIED/git/python — plus `gh` (used on plain command lines,
# not in spans, but advertised in the PR body) and `TORTOISE_TEST_CARVE_OUT` (the env-assignment
# prefix the body names). Over-stubbing cannot false-fire: a stub is only written when that name is
# actually looked up on PATH. `git` and `python` were MISSING before this review, and both are live.
for c in uv find rg du mdfind ls UNVERIFIED git gh python TORTOISE_TEST_CARVE_OUT; do
  printf '#!/bin/bash\nprintf "%%s\\n" "%s" >> "%s"\nexit 0\n' "$c" "$NB/trip" > "$NB/bin/$c"
  chmod +x "$NB/bin/$c"
done
printf '#!/bin/bash\nprintf "%%s\\n" ".venv/bin/python" >> "%s"\nexit 0\n' "$NB/trip" > "$NB/repo/.venv/bin/python"
chmod +x "$NB/repo/.venv/bin/python"
# Extracts a script's FIRST prompt heredoc verbatim: the opening `cat > ... <<EOF`, the body, `EOF`.
nb_extract() { # nb_extract <script> <out-file>
  awk '/^cat > .*<<EOF$/{f=1; print; next} f&&/^EOF$/{print; exit} f{print}' "$1" > "$2"
}
nb_ticks_escaped() { # nb_ticks_escaped <script> -> 0 iff EVERY backtick in its heredoc is escaped
  nb_extract "$1" "$NB/snip.sh"
  [ -s "$NB/snip.sh" ] || return 1
  set -- $(awk '{n+=gsub(/`/,"&"); m+=gsub(/\\`/,"&")} END{printf "%d %d\n", n+0, m+0}' "$NB/snip.sh")
  [ "${1:-0}" -gt 0 ] && [ "${1:-0}" -eq "${2:-0}" ]
}
# Expands the script's first prompt heredoc the way a real run does: SOURCED into a shell carrying
# the same variables (the shipped scripts use unexported $L/$O/$N in the heredoc target).
nb_expand() { # nb_expand <script>
  nb_extract "$1" "$NB/snip.sh"
  [ -s "$NB/snip.sh" ] || return 1
  ( set +u; cd "$NB/repo"; PATH="$NB/bin:$PATH"
    O="$NB/o"; REPO="$NB/repo"; OR="owner/repo"; PR=7; BR="chore/x"; N=7; L="$NB/log"
    WT="$NB/repo/.worktrees/wt"; KIND=x; TAG=x
    # #2148: lane.sh splices the reviewer brief in as a PRECOMPUTED variable (never a
    # `$(...)` inside the unquoted heredoc — that is the bug class this rig exists for).
    # The rig renders it from the SHIPPED helper so the assertion below sees real text.
    REVIEWER_BRIEF="$(bash "$HERE/reviewer-preflight.sh" --brief harness)"
    # #2325: lane.sh ALSO splices the landing-artifacts section as a precomputed variable. Rendered
    # here from the SHIPPED helper for the same reason: under `set +u` an unset variable expands to
    # nothing, so without this line every prompt this rig builds would silently lack the section and
    # none of its backtick spans would be exercised.
    LANDING_BRIEF="$(bash "$HERE/reviewer-preflight.sh" --landing-brief harness)"
    . "$NB/snip.sh" ) >/dev/null 2>&1
}
if nb_expand "$MERGE"; then
  { grep -qF 'NEVER run' "$NB/log-reviewer.txt" && grep -qF '`UNVERIFIED`' "$NB/log-reviewer.txt" \
    && grep -qF '`uv sync`' "$NB/log-reviewer.txt" && grep -qF 'many minutes' "$NB/log-reviewer.txt"; }; rc=$?
else rc=1; fi
ck "merge-one.sh's reviewer prompt carries the no-search bound with its backticks LITERAL" $rc
if nb_expand "$HERE/lane.sh"; then
  { grep -qF 'never search the filesystem for an interpreter' "$NB/o/logs/prompt-7.txt" \
    && grep -qF '`uv sync --extra embeddings --extra parity`' "$NB/o/logs/prompt-7.txt" \
    && grep -qF 'TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python -m pytest' "$NB/o/logs/prompt-7.txt"; }; rc=$?
else rc=1; fi
ck "lane.sh's prompt keeps its test command AND forbids searching for an interpreter" $rc
# #2148: the generated brief must CARRY the reviewer step. This is the same expanded artifact the
# check above reads (not a source grep), so a heredoc edit that loses the section goes red here.
if nb_expand "$HERE/lane.sh"; then
  { grep -qF '## Reviewer step' "$NB/o/logs/prompt-7.txt" \
    && grep -qF 'must dispatch a reviewer and record an attestation at the final head before the rail' "$NB/o/logs/prompt-7.txt" \
    && grep -qF 'scripts/record-review.sh <PR> <HEAD> clean' "$NB/o/logs/prompt-7.txt" \
    && grep -qF 'scripts/admin-merge.sh <PR>' "$NB/o/logs/prompt-7.txt" \
    && grep -qF 'do NOT dispatch it' "$NB/o/logs/prompt-7.txt"; }; rc=$?
else rc=1; fi
ck "lane.sh's prompt CARRIES the #2148 reviewer step (requirement + record + rail, harness role)" $rc
# #2325: and the LANDING ARTIFACTS section, from the same expanded artifact. A heredoc edit that
# loses it (or a splice that quietly renders empty) goes red here rather than at a compliance gate.
if nb_expand "$HERE/lane.sh"; then
  { grep -qF '## Landing artifacts' "$NB/o/logs/prompt-7.txt" \
    && grep -qF 'Do NOT reach for "Refs #' "$NB/o/logs/prompt-7.txt" \
    && grep -qF 'scripts/admin-merge.sh <PR>' "$NB/o/logs/prompt-7.txt"; }; rc=$?
else rc=1; fi
ck "lane.sh's prompt CARRIES the #2325 landing artifacts ([a] issue ref line, [c] record command)" $rc
if nb_expand "$HERE/fix-one.sh"; then
  { grep -qF 'Never search the filesystem for an interpreter' "$NB/log-fixer.txt" \
    && grep -qF '`uv sync --extra embeddings --extra parity`' "$NB/log-fixer.txt" \
    && grep -qF 'TORTOISE_TEST_CARVE_OUT=1 .venv/bin/python -m pytest' "$NB/log-fixer.txt"; }; rc=$?
else rc=1; fi
ck "fix-one.sh's prompt keeps its test command AND forbids searching for an interpreter" $rc
[ -s "$NB/trip" ] && rc=1 || rc=0
[ "$rc" -eq 0 ] || { echo "      a stub EXECUTED at prompt-build time: $(sort -u "$NB/trip" | tr '\n' ' ')"; }
ck "no command inside the three prompts' backtick spans ran at prompt-build time (unescaped backtick)" $rc
rc=0
for f in "$MERGE" "$HERE/lane.sh" "$HERE/fix-one.sh"; do
  nb_ticks_escaped "$f" || { rc=1; echo "      $(basename "$f"): a BARE backtick in the prompt heredoc — command substitution at prompt-build time"; }
done
ck "every backtick in the three prompt heredocs is ESCAPED (name-blind — covers commands no stub can intercept)" $rc
# NON-VACUITY (execution): the identical rig on a deliberately unescaped heredoc MUST fire, or the
# check above proves nothing (a rig that can never fire is the "test that cannot fail" class).
: > "$NB/trip"
cat > "$NB/neg.sh" <<'NEG'
cat > "$NEGOUT" <<EOF
Release it as `UNVERIFIED` and then run `uv sync`.
EOF
NEG
NEGOUT="$NB/neg.out" NEGPATH="$NB/bin" bash -c 'set +u; PATH="$NEGPATH:$PATH"; NEGOUT="$NEGOUT"; . "$1"' _ "$NB/neg.sh" >/dev/null 2>&1
{ [ -s "$NB/trip" ] && ! grep -qF 'UNVERIFIED' "$NB/neg.out"; }; rc=$?
ck "non-vacuity: the same rig FIRES on a bare-backtick heredoc and ERASES the literal" $rc
# NON-VACUITY (`git`): the class the review found PASSING — a bare span whose command ran for real
# because `git` was never stubbed. The stub must now record it.
: > "$NB/trip"
cat > "$NB/neg-git.sh" <<'NEG'
cat > "$NEGOUT" <<EOF
Stage specific files; never `git add -A`.
EOF
NEG
NEGOUT="$NB/neg-git.out" NEGPATH="$NB/bin" bash -c 'set +u; PATH="$NEGPATH:$PATH"; NEGOUT="$NEGOUT"; . "$1"' _ "$NB/neg-git.sh" >/dev/null 2>&1
{ [ -s "$NB/trip" ] && grep -qxF 'git' "$NB/trip"; }; rc=$?
ck "non-vacuity: the tripwire FIRES on a bare \`git\` span (the class that passed before this fix)" $rc
# NON-VACUITY (textual): `-maxdepth` is not a command and cannot be stubbed, so the execution rig
# is blind to it — but unescaped it erases prompt text. Mutate the REAL merge-one.sh prompt and the
# name-blind census must go unequal.
sed 's/\\`-maxdepth\\`/`-maxdepth`/' "$MERGE" > "$NB/mut-merge.sh"
nb_ticks_escaped "$NB/mut-merge.sh" && rc=1 || rc=0
ck "non-vacuity: the name-blind check FIRES on a bare \`-maxdepth\` that no stub can intercept" $rc

# NOTE (BP0, tortoise#8468 — reconciled onto main, NOT shipped): the tortoise fork's P0
# merge-priority override and its `.prio` rank map are NOT carried here. main's drain rule is
# unconditional (owner ruling, 2026-10-18: "while ONE un-owned PR remains, it is the work"), so
# a P0 exception would reopen new issue work on top of an un-worked PR queue. The assertions
# that used to drive that override (and the `.prio` writer) went with it; refresh-candidates
# keeps its single `.pool` artifact, and that IS covered by the #8465 ordering check above.

# ── the reviewer's verdict classifies into THREE outcomes, and only one authorises a fixer ────
# agent-infra#2132 (superseding the #8602 port this section used to drive): a verdict-less run
# (stall/crash/timeout) and a real `ISSUES` verdict must never share an arm, because
# `needsfix-<PR>-<head>` is the only thing that spawns a FIXER — and the two remedies differ (a fixer
# vs another REVIEW). The pre-#2132 arm wrote the FIXER marker for BOTH, which burnt a MAX_FIX_TRIES
# attempt per stall and parked PRs that had never been reviewed. These drive the SHIPPED functions;
# a grep would stay green if an arm were deleted. The producer is now the #2132 pair
# (`verdict_class` + `review_state_record`), so the SAME contracts are pinned at the new API:
#   empty/unrecognised -> NO-VERDICT    |   `ISSUES 0` -> NO-VERDICT (the count is part of the verdict)
#   ISSUES -> needsfix marker           |   NO-VERDICT -> needsreview marker and NO needsfix
#   an empty head writes nothing (a marker must name a head)
if [ -s "$MERGE" ]; then
  { awk '/^verdict_class\(\) \{/{f=1} f{print} f && /^\}/{c++} f && c==1{exit}' "$MERGE"
    awk '/^review_state_record\(\) \{/{f=1} f{print} f && /^\}/{c++} f && c==1{exit}' "$MERGE"; } > "$TMP/verdict.sh" 2>/dev/null
  if [ -s "$TMP/verdict.sh" ] && grep -q 'verdict_class' "$TMP/verdict.sh" \
     && grep -q 'review_state_record' "$TMP/verdict.sh"; then
    vk() { ( . "$TMP/verdict.sh"; verdict_class "$1" ); }
    [ "$(vk 'CLEAN https://x/1')" = CLEAN ] && rc=0 || rc=1
    ck "verdict_class: a CLEAN verdict classifies as CLEAN" $rc
    [ "$(vk 'ISSUES 3')" = ISSUES ] && rc=0 || rc=1
    ck "verdict_class: an ISSUES verdict classifies as ISSUES" $rc
    [ "$(vk '')" = NO-VERDICT ] && rc=0 || rc=1
    ck "verdict_class: an EMPTY verdict is NO-VERDICT (a stall is not a finding)" $rc
    [ "$(vk 'garbage without a verdict')" = NO-VERDICT ] && rc=0 || rc=1
    ck "verdict_class: an unrecognised line is NO-VERDICT, never ISSUES" $rc
    [ "$(vk 'ISSUES 0')" = NO-VERDICT ] && rc=0 || rc=1
    ck "verdict_class: ISSUES 0 is NO-VERDICT (a zero count authorises no fixer)" $rc

    # The marker is what authorises the fixer, so drive its WRITE behaviour, not just its name.
    vdir="$TMP/vmark"; mkdir -p "$vdir/state"
    # ⛔ A VAR IN FRONT OF `.` APPLIES ONLY TO THE SOURCE, not to the function called after it — so
    # `O=… . file; fn` runs fn with O UNSET (the same per-command-env trap that bit an earlier test).
    # The whole call is one subshell here.
    m1="$( O="$vdir" PR=42 HEAD=abc123 L="$vdir/log" MAX_REVIEW_TRIES=3 bash -c '. "$1"; review_state_record ISSUES' _ "$TMP/verdict.sh" )"
    [ -f "$vdir/state/needsfix-42-abc123" ] && [ ! -f "$vdir/state/needsreview-42-abc123" ] && rc=0 || rc=1
    ck "review_state_record: an ISSUES verdict WRITES needsfix-<PR>-<head> (the fixer's authority)" $rc
    rm -f "$vdir"/state/needsfix-* "$vdir"/state/needsreview-* "$vdir"/state/reviewcount-* 2>/dev/null
    m2="$( O="$vdir" PR=42 HEAD=abc123 L="$vdir/log" MAX_REVIEW_TRIES=3 bash -c '. "$1"; review_state_record NO-VERDICT' _ "$TMP/verdict.sh" )"
    [ -f "$vdir/state/needsreview-42-abc123" ] && [ ! -f "$vdir/state/needsfix-42-abc123" ] && rc=0 || rc=1
    ck "review_state_record: a verdict-LESS run writes needsreview (another REVIEW), never needsfix (no fixer)" $rc
    rm -f "$vdir"/state/needsfix-* "$vdir"/state/needsreview-* "$vdir"/state/reviewcount-* 2>/dev/null
    m3="$( O="$vdir" PR=43 HEAD="" L="$vdir/log" MAX_REVIEW_TRIES=3 bash -c '. "$1"; review_state_record ISSUES' _ "$TMP/verdict.sh" )"
    [ -z "$(ls -A "$vdir/state" 2>/dev/null)" ] && rc=0 || rc=1
    ck "review_state_record: an empty head writes no marker (a marker must name a head)" $rc
  else
    ck "merge-one.sh carries verdict_class/review_state_record (#2132)" 1
  fi
fi

echo
# ── platform-gate self-check (NON-VACUITY) ──────────────────────────────────────
# A green run must never be green BECAUSE everything was skipped — that is a false PASS of the class
# `AGENTS.md` names. On macOS the gate must skip NOTHING (the install.sh checks are reachable there);
# off macOS every skip is an install.sh-driven group and the run must still have exercised the bulk
# of the suite (the classifier/reaper/parity checks), so a widened gate cannot go unnoticed.
if on_darwin; then
  [ "$skip" -eq 0 ] && rc=0 || { rc=1; echo "      platform gate skipped $skip group(s) on Darwin — the gated checks MUST run here"; }
  ck "platform gate: macOS runs every gated check (a skip is never a pass)" $rc
else
  [ "$skip" -gt 0 ] && [ "$pass" -ge 250 ] && rc=0 \
    || { rc=1; echo "      skip=$skip pass=$pass — a $PLATFORM run must skip ONLY the install.sh groups, not the suite"; }
  ck "platform gate: $PLATFORM skips only install.sh-driven checks and still runs the suite ($pass checks)" $rc
fi
if [ "$skip" -gt 0 ]; then
  echo "==> $skip install-check group(s) SKIPPED (platform=$PLATFORM; install.sh is macOS-only) — a skip is NOT a pass"
fi
echo "==> $pass passed, $fail failed"
[ "$fail" -eq 0 ]
