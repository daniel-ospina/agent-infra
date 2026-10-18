#!/usr/bin/env bash
# harness.test.sh — the ONE entry point must deploy, refuse, and report honestly.
#
# Run: bash scripts/orchestrator-harness/harness.test.sh
# Exits 0 when ALL assertions pass, non-zero on any failure. HERMETIC: a throwaway $HOME, a throwaway
# $O, and — where a verdict about launchd is needed — a `launchctl` stub first on PATH. It never
# touches real launchd, ~/Library/LaunchAgents, or the live controller, and it never runs a mutating
# verb (`stop`/`restart`), because those are gated by ELDATO_ALLOW_TEST_HOME + a plist-identity guard
# and are covered by install-launchd-durability.test.sh.
#
# WHAT IT PINS, and the measured failure behind each:
#
#   1. NO RECORD IS NOT A PASS. `harness.sh drift` on a deployment with no
#      `.agent-infra-stamp.json` exits 2 (cannot determine), never 0. This is the state the live box
#      was measured in: the deployed installer was an older commit's bytes and NOTHING could say so,
#      because the deploy path (`cp -R` inside bg/finish.sh) never wrote a record.
#   2. DEPLOY MAKES THE BOX ANSWERABLE. After `deploy`, the record exists and `drift` exits 0 with a
#      per-file `identical:` line for every shipped script (--all).
#   3. A STALE DEPLOYED FILE IS NAMED, per file, with a non-zero exit — the delivered defect.
#   4. A SCRIPT THE HARNESS NO LONGER SHIPS IS NAMED (mirror, not overlay): a retired script left in
#      $O stays invocable and is reported as `present in $O but NOT shipped`.
#   5. DEPLOY IS ALL-OR-NOTHING. A differing orch-loop.sh under a running controller is the corruption
#      supervisor.sh warns about (bash reads scripts incrementally); deploy must refuse BEFORE writing
#      anything, so the OTHER files it would have replaced are still the old bytes.
#   6. A REMOVAL IS NEVER A SIDE EFFECT (#2044 review finding 4). `$O` is the LIVE directory a running
#      fleet execs by absolute path, so a file the repo does not ship is refused — named, with
#      nothing written — unless `--prune` asks for exactly that. This holds for `restart` too,
#      because restart is the documented RECOVERY and it reached the deletions.
#   6. VERIFY DISTINGUISHES RED FROM UNKNOWN. A label launchd does not have → exit 1 (red); a launchd
#      that cannot be read → exit 2 (cannot determine), never 0 and never the same code as red.
#   7. THE RECORD COVERS THE NON-`.sh` SHIPPED SURFACE, AND IS BUILT FROM THE REPO (#1960). Deleting
#      `$O/gh-limit.py` or `$O/gh-rest/gh` — neither of which a `*.sh` record can see — makes `drift`
#      exit 1 and NAME the file MISSING, while the stamp still lists it; and a stamp that omits a
#      shipped path is itself drift, because a record cannot report a file it does not list.

# ⛔ ON LINUX, 31 OF THESE ASSERTIONS USED TO SKIP AND THE SUITE STILL EXITED 0 (#2044 finding 9).
# `DEPLOY_OK=0` whenever `uname != Darwin`, so sections 4–8 were skipped and the summary printed PASS
# — in the ONLY lane that runs CI. The suite's headline claims were therefore unverified where the
# merge is gated. The fix is not to hide the skips: `install.sh` really does refuse non-Darwin, so a
# full deploy cannot be asserted on Linux. It is to assert the guarantees that need NO installer,
# NO launchd and NO Darwin — the plan/refusal phase (#2) and the launchd classification (#7) — on
# every platform, and to FAIL if that neutral path did not actually run (see `NEUTRAL_GATE`).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HARNESS="$SCRIPT_DIR"
SELF="$HARNESS/harness.sh"
GITTOP="$(git -C "$HARNESS" rev-parse --show-toplevel 2>/dev/null || true)"

PASS=0; FAIL=0; SKIP=0
# Set once the platform-neutral refusal path (#2) has actually executed. A suite that skips every
# falsifiable assertion must not report success, so this is asserted at the end (#2044 finding 9).
NEUTRAL_GATE=0
ok()    { PASS=$((PASS + 1)); printf '  \033[32mPASS\033[0m  %s\n' "$1"; }
bad()   { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m  %s\n' "$1"; }
skipd() { SKIP=$((SKIP + 1)); printf '  \033[33mSKIP\033[0m  %s\n' "$1"; }
assert_eq() { [ "$1" = "$2" ] && ok "$3" || bad "$3 (got: '$1', want: '$2')"; }
assert_contains() { if grep -qF -- "$2" <<<"$1"; then ok "$3"; else bad "$3 (missing: $2)"; fi; }
assert_absent()   { if grep -qF -- "$2" <<<"$1"; then bad "$3 (found: $2)"; else ok "$3"; fi; }

[ -f "$SELF" ] || { echo "harness.test: missing $SELF" >&2; exit 1; }

SB="$(mktemp -d 2>/dev/null || true)"
[ -n "$SB" ] || { echo "harness.test: cannot create a temp dir" >&2; exit 1; }
trap 'rm -rf "$SB"' EXIT

# A `gh` stub: install.sh requires `gh auth status` to pass, and the sandbox HOME has no gh config.
# Nothing else about gh is exercised by a deploy that mutates no launchd state.
mkdir -p "$SB/bin" "$SB/home/Library/LaunchAgents" "$SB/orchestrator"
cat > "$SB/bin/gh" <<'STUB'
#!/bin/bash
case "${1:-}" in
  --version) echo "gh version 2.99.0 (sandbox stub)" ;;
esac
exit 0
STUB
chmod +x "$SB/bin/gh"

# A launchctl stub whose answers are chosen per section by $STUB_LC. Two shapes matter:
#   silent-fail  → `launchctl print` exits non-zero printing NOTHING = an UNREADABLE domain (exit 2)
#   not-loaded   → launchd's real "Could not find service" shape = the label is absent (exit 1)
cat > "$SB/bin/launchctl" <<'STUB'
#!/bin/bash
case "${STUB_LC:-not-loaded}" in
  silent-fail) exit 1 ;;
  *)
    case "${1:-}" in
      print) echo "Could not find service \"${2##*/}\" in domain for user" >&2; exit 113 ;;
      list)  : ;;
      *)     : ;;
    esac ;;
esac
exit 0
STUB
chmod +x "$SB/bin/launchctl"

export PATH="$SB/bin:$PATH"
export HOME="$SB/home"
export O="$SB/orchestrator"
# REPO is the CONTROLLER's target checkout, and install.sh validates it with `git rev-parse` — a bare
# empty directory is refused ("not a git checkout"), which is the correct behaviour and not what this
# test is about. The harness's own checkout stands in: nothing is ever started against it.
export REPO="$GITTOP"
export OR="daniel-ospina/tortoise"
export ELDATO_ALLOW_TEST_HOME=1
export HARNESS_REF="HEAD"
export LABEL="com.example.harness-test-stack"   # never a production label
unset HARNESS_NO_FETCH

run() { # <expected-nonzero|0> <label> <cmd...>
  local want="$1" label="$2"; shift 2
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  if [ "$want" = "0" ]; then
    [ "$rc" -eq 0 ] && ok "$label" || { bad "$label (exit $rc)"; printf '%s\n' "$out" | tail -6 | sed 's/^/        /'; }
  else
    [ "$rc" -ne 0 ] && ok "$label" || { bad "$label (exit 0, expected non-zero)"; printf '%s\n' "$out" | tail -6 | sed 's/^/        /'; }
  fi
  LAST_OUT="$out"
}

# ── preflight: the deploy sections need the real installer's dependencies ───────────────────────
DEPLOY_OK=1; WHY=""
[ "$(uname)" = "Darwin" ] || { DEPLOY_OK=0; WHY="install.sh refuses non-Darwin"; }
for b in tmux gh pi jq plutil git; do command -v "$b" >/dev/null 2>&1 || { DEPLOY_OK=0; WHY="$b not on PATH"; }; done
[ -n "$GITTOP" ] || { DEPLOY_OK=0; WHY="the harness is not in a git checkout, so nothing can be deployed from it"; }
# install.sh refuses an unauthenticated gh (the daemon's listings would read an empty queue and idle),
# so a box without it cannot run the deploy sections — a SKIP here, not a failure of this suite.
if [ "$DEPLOY_OK" -eq 1 ] && ! gh auth status >/dev/null 2>&1; then DEPLOY_OK=0; WHY="gh is not authenticated (install.sh refuses)"; fi

echo "== 1. no provenance record is UNKNOWN, never a pass"
mkdir -p "$O"
cp "$HARNESS"/*.sh "$O"/ 2>/dev/null
out="$("$SELF" drift 2>&1)"; rc=$?
assert_eq "$rc" "2" "drift with no record exits 2 (cannot determine)"
assert_contains "$out" "NOT a pass" "it says so — cannot-verify is not a pass"

echo "== 2. deploy REFUSES before writing — on EVERY platform"
# ⛔ THE TWO HEADLINE GUARANTEES, ASSERTED WHERE CI ACTUALLY RUNS (#2044 finding 9). Both live in the
# plan/gate phase, before install.sh is ever invoked, so neither needs Darwin or launchd. The later
# sections keep the same assertions for the full macOS deploy; these are the ones a Linux runner runs.
printf '#!/usr/bin/env bash\nsleep 20\n' > "$O/orch-loop.sh"     # differs from the shipped copy
printf '\n# stale: an older commit did not have this line\n' >> "$O/install.sh"
bash "$O/orch-loop.sh" & STUB_PID=$!
sleep 1
out="$("$SELF" deploy 2>&1)"; rc=$?
kill "$STUB_PID" 2>/dev/null; wait "$STUB_PID" 2>/dev/null
assert_eq "$rc" "1" "deploy refuses while a controller executes orch-loop.sh"
assert_contains "$out" "Nothing was written" "the refusal says nothing was written"
# The half-deploy assertion: if deploy had written file-by-file it would already have repaired the
# drifted install.sh by the time it noticed orch-loop.sh. It must still hold the stale bytes.
if grep -qF '# stale: an older commit did not have this line' "$O/install.sh"; then
  ok "the OTHER drifted file was NOT written (no half-deploy)"
else
  bad "install.sh was replaced before the refusal — the deploy is not all-or-nothing"
fi
cp "$HARNESS/install.sh" "$O/install.sh"; cp "$HARNESS/orch-loop.sh" "$O/orch-loop.sh"

# ⛔ #2044 review finding 4, the destructive path. `deploy`/`restart` used to `rm -f` ANY top-level
# `.sh` in $O the repo does not ship, with no allowlist and a `warn` on stdout as the only evidence —
# and `restart`, the DOCUMENTED RECOVERY, performed the deletions. A file a human left there is not a
# retired harness script. Removal must be an explicit request.
printf '#!/usr/bin/env bash\n# a human put this here; the harness does not ship it\n' > "$O/keys.sh"
out="$("$SELF" deploy 2>&1)"; rc=$?
assert_eq "$rc" "1" "deploy refuses when \$O holds a script the harness does not ship"
assert_contains "$out" "keys.sh" "the refusal NAMES the file it will not delete"
assert_contains "$out" "--prune" "it names the explicit request that would delete it"
assert_contains "$out" "Nothing was written" "…and says nothing was written"
[ -f "$O/keys.sh" ] && ok "the file is still there (no side-effect deletion)" \
  || bad "deploy deleted a file it was not asked to delete"
# THE SAME GATE ON THE RECOVERY VERB, AND BEFORE ANYTHING IS STOPPED — a restart that stops the fleet
# and only then discovers it would delete a file nobody agreed to delete is the reachable failure.
out="$(STUB_LC=not-loaded "$SELF" restart 2>&1)"; rc=$?
assert_eq "$rc" "1" "restart refuses too (it is the documented recovery, and it reached the deletions)"
assert_absent "$out" "==> booting out" "…and refuses BEFORE touching launchd"
assert_contains "$out" "keys.sh" "…naming the same file"
[ -f "$O/keys.sh" ] && ok "restart did not delete it either" || bad "restart deleted a file it was not asked to delete"

# …and the explicit request is HONOURED, exactly. `--prune` is the operator's decision, per run.
out="$("$SELF" deploy --prune 2>&1)"; rc=$?
assert_contains "$out" "prune plan (--prune): remove keys.sh" "--prune prints the plan before writing"
[ -f "$O/keys.sh" ] && bad "--prune did not remove the named file" || ok "--prune removed EXACTLY the named file"
assert_absent "$out" "refusing to deploy" "…and it is not the refusal path"
# An option this verb does not know is a usage error, never silently ignored.
run 2 "an unknown deploy option exits 2" "$SELF" deploy --frobnicate
assert_contains "$LAST_OUT" "unknown option for deploy" "…and it names the option"
NEUTRAL_GATE=1

echo "== 3. deploy makes the box answerable"
if [ "$DEPLOY_OK" -ne 1 ]; then
  skipd "deploy sections skipped: $WHY"
elif [ -n "$GITTOP" ] && [ -n "$(git -C "$GITTOP" status --porcelain -- "$HARNESS" 2>/dev/null)" ]; then
  # deploy copies the WORKING TREE and drift compares it with the REF, so uncommitted edits make
  # "the deploy matches the ref" false by construction. Say that instead of reporting a false failure.
  skipd "deploy sections skipped: $HARNESS has uncommitted changes vs $HARNESS_REF (commit, or set HARNESS_REF=<branch>)"
else
  run 0 "deploy exits 0" "$SELF" deploy
  out="$("$SELF" drift --all 2>&1)"; rc=$?
  assert_eq "$rc" "0" "drift after deploy exits 0 (MATCH)"
  assert_contains "$out" "identical: install.sh" "--all prints a per-file SAME line"
  assert_contains "$out" "identical: supervisor.sh" "the versioned supervisor is part of the deployed surface"
  [ -f "$O/.agent-infra-stamp.json" ] && ok "the deploy wrote a provenance record" || bad "no provenance record after deploy"

  echo "== 4. a stale deployed file is named, and the exit is non-zero"
  # Stands for "the deployed installer is an OLDER COMMIT's bytes" — the measured live state. Synthetic
  # rather than `HEAD~1` so the assertion does not depend on what the previous commit happened to touch.
  printf '\n# stale: an older commit did not have this line\n' >> "$O/install.sh"
  out="$("$SELF" drift 2>&1)"; rc=$?
  assert_eq "$rc" "1" "a stale install.sh makes drift exit 1 (not 0, not 2)"
  assert_contains "$out" "install.sh — the deployed copy DIFFERS" "it names the stale file"
  assert_contains "$out" "changed after it was recorded" "it names the hand edit that the payload hash caught"

  echo "== 5. a script the harness no longer ships is named"
  printf '#!/usr/bin/env bash\n# retired upstream\n' > "$O/run-wrapped.sh"
  out="$("$SELF" drift 2>&1)"; rc=$?
  assert_eq "$rc" "1" "an unshipped script in \$O makes drift exit 1"
  assert_contains "$out" "run-wrapped.sh — present in /" "it names the unshipped script"
  rm -f "$O/run-wrapped.sh"
  # §4's stale edit is left in place ON PURPOSE for §5 (a second drift cause must not mask the first);
  # restore it here so §6 can assert a full-surface MATCH rather than re-testing §4.
  cp "$HARNESS/install.sh" "$O/install.sh"

  echo "== 6. the record covers the NON-.sh shipped surface, and names its absence (#1960)"
  # ⛔ THE DEFECT THIS SECTION EXISTS FOR, measured on the laptop 2026-10-18. `$O/gh-limit.py` was ABSENT
  # from the live deployment while present on origin/main. The record covered `$O/*.sh`, so a `.py` could
  # never be in it; `$O/gh-rest/gh:102` resolves `$SELF_DIR/../gh-limit.py`, so the shim printed
  # `gh-rest: WARNING no limit layer … this call was NOT serialised or backed off (#1988)` and fell back
  # to the raw binary, which failed outright (`GraphQL: API rate limit already exceeded`). Every
  # `gh issue view`/`gh pr list` was refused → pre-flight DEGRADED/INCOMPLETE → refresh-candidates.sh
  # aborts by design (#1736) → candidates.txt stayed 0 lines for 4.5 h → `[dispatch] backlog empty
  # queue=READ(203)` with 200 issues open and 19 of 20 lane slots free. Nothing below is about the
  # `.sh` payload hash: gh-limit.py is not a `.sh`, so ONLY the per-file shipped-surface record can
  # see it. `assert_absent` on the payload line is what keeps these assertions honest.
  stamp="$O/.agent-infra-stamp.json"
  assert_contains "$(cat "$stamp")" '"gh-limit.py": "' "the record carries a per-file hash for a shipped .py"
  assert_contains "$(cat "$stamp")" '"gh-rest/gh": "' "…and for the gh-rest shim (no .sh in its name either)"
  assert_absent "$(cat "$stamp")" '"retired/' "…and NOT for a file the surface declares not-shipped"
  out="$("$SELF" drift --all 2>&1)"; rc=$?
  assert_eq "$rc" "0" "a full-surface deployment matches (the .py and the shims are shipped, not tolerated)"
  assert_contains "$out" "identical: gh-limit.py" "--all prints gh-limit.py as a SAME file"
  assert_contains "$out" "identical: gh-rest/gh" "--all prints the gh-rest shim as a SAME file"
  # 1. the missing LIMIT LAYER — the exact file the measurement lost
  rm -f "$O/gh-limit.py"
  out="$("$SELF" drift 2>&1)"; rc=$?
  assert_eq "$rc" "1" "deleting the non-.sh limit layer makes drift exit 1 (not 0, not 2)"
  assert_contains "$out" "gh-limit.py — shipped by the repo at" "it names gh-limit.py"
  assert_contains "$out" "MISSING from" "…as MISSING, not as an absence nothing can see"
  # ⛔ THE RECORD IS BUILT FROM THE REPO, NOT FROM THE DEPLOYMENT — the whole point of #1960. A record
  # that scanned $O could not name a file $O no longer has; this one still does.
  assert_contains "$(cat "$stamp")" '"gh-limit.py": "' "the record STILL names gh-limit.py after the deployment lost it (repo-derived)"
  cp "$HARNESS/gh-limit.py" "$O/gh-limit.py"
  # 2. the REST ADAPTER SHIM — a shipped file in a subdirectory, also not a .sh file at depth 1
  rm -f "$O/gh-rest/gh"
  out="$("$SELF" drift 2>&1)"; rc=$?
  assert_eq "$rc" "1" "deleting gh-rest/gh makes drift exit 1"
  assert_contains "$out" "gh-rest/gh — shipped by the repo at" "it names the shim by its SUBDIRECTORY path"
  cp "$HARNESS/gh-rest/gh" "$O/gh-rest/gh"; chmod +x "$O/gh-rest/gh"
  # 3. a record that OMITS a shipped path cannot report that path missing — grade the record itself.
  # The count line goes too: with the count still claiming 43 files over a 42-entry list, the check
  # correctly answers CANNOT-DETERMINE (two of the record's own claims disagree), which is a different
  # verdict from the one this case is about.
  cp "$stamp" "$SB/stamp.keep"
  grep -vF '"gh-limit.py": "' "$SB/stamp.keep" | grep -vF '"shippedFileCount": ' > "$stamp"
  out="$("$SELF" drift 2>&1)"; rc=$?
  assert_eq "$rc" "1" "a record missing a shipped path is drift, not a pass"
  assert_contains "$out" "gh-limit.py — shipped by" "…and the path it omits is named"
  assert_contains "$out" "NOT named in the record at" "…with the reason: the record cannot report what it does not list"
  cp "$SB/stamp.keep" "$stamp"
  out="$("$SELF" drift 2>&1)"; rc=$?
  assert_eq "$rc" "0" "restoring the complete record restores MATCH"
  # a record whose own COUNT disagrees with its own list is CANNOT-VERIFY, never a pass and never a
  # drift verdict: nothing can say which of the record's two claims is the damaged one.
  sed 's/"shippedFileCount": [0-9]*/"shippedFileCount": 999/' "$SB/stamp.keep" > "$stamp"
  out="$("$SELF" drift 2>&1)"; rc=$?
  assert_eq "$rc" "2" "a record whose count disagrees with its list is UNKNOWN (exit 2)"
  assert_contains "$out" "count and its own list disagree" "…and it says which two claims disagree"
  cp "$SB/stamp.keep" "$stamp"
fi

echo "== 7. verify distinguishes RED from UNKNOWN"
# ⛔ PLATFORM-NEUTRAL, and moved out of the Darwin gate for that reason (#2044 finding 9): the
# classification is produced by the launchd probe + the drift verdict, neither of which needs install.sh.
# The CLASSIFICATION IS WHAT IS ASSERTED, not the aggregate exit code: in a sandbox $O that has no live
# stack, "no controller running" is RED no matter what launchd says, so the aggregate would be 1 in
# both cases and the assertion would pass without exercising anything. What must differ is how the
# LAUNCHD component is classified — and "absent" and "unreadable" are different facts about different
# worlds (launchd answered vs launchd did not).
out="$(STUB_LC=not-loaded "$SELF" verify 2>&1)"; rc=$?
assert_contains "$out" "is NOT loaded" "an absent label is reported as NOT loaded (RED)"
assert_absent "$out" "launchd's state for $LABEL could not be read" "…and does not claim the read failed"
[ "$rc" -ne 0 ] && ok "verify exits non-zero when the job is absent" || bad "verify exited 0 with the job absent"
out="$(STUB_LC=silent-fail "$SELF" verify 2>&1)"; rc=$?
assert_contains "$out" "UNKNOWN launchd's state for" "an unreadable domain is classified UNKNOWN, not RED"
assert_absent "$out" "is NOT loaded" "…and 'not loaded' is NOT asserted from a read that failed"
[ "$rc" -ne 0 ] && ok "verify exits non-zero on an unreadable domain (it is never a pass)" || bad "verify exited 0 with launchd unreadable"

echo "== 8. a restart that does not come up is NOT a successful restart"
# The launchctl stub makes every launchd verb "succeed" while the job never appears — which is exactly
# the false PASS #1975 paid for (installer exits 0, controller removed and disabled). `restart` must
# exit non-zero and say so. The SUCCESS path is launchd-cycle.sh's lc_restart, pinned by
# install-launchd-durability.test.sh's 269 checks; what is pinned here is this file's own verdict.
if [ "$DEPLOY_OK" -ne 1 ]; then
  skipd "restart verdict skipped: $WHY"
else
  out="$(STUB_LC=not-loaded START_TIMEOUT=2 "$SELF" restart 2>&1)"; rc=$?
  assert_eq "$rc" "1" "restart exits 1 when the job never comes up"
  assert_contains "$out" "NOT a successful restart" "it says the restart did not succeed"
  assert_contains "$out" "could not be PROVEN" "the refusal names what install.sh --restart checks"
  assert_absent "$out" "restart: done" "it does not print a completion line"
fi

echo "== 9. the verb surface is the documented one"
run 0 "harness.sh --help exits 0" "$SELF" --help
for v in status verify drift deploy stop restart; do
  assert_contains "$LAST_OUT" "harness.sh $v" "--help documents '$v'"
done
run 2 "an unknown verb exits 2" "$SELF" frobnicate

echo
echo "== the neutral path RAN — a suite that skips everything is not a pass (#2044 finding 9)"
# ⛔ THE ANTI-VACUITY GUARD, ONE LAYER ABOVE THE PER-ASSERTION SKIPS. `selftest.sh` §P and CI only see
# this file's exit code, so a future change that made every falsifiable path conditional (a new
# `DEPLOY_OK` precondition, a `command -v` that is absent on the runner) would turn this suite back
# into a green no-op. This assertion is what fails instead.
if [ "$NEUTRAL_GATE" -eq 1 ]; then
  ok "the platform-neutral refusal path executed (deploy refuses before writing on THIS platform)"
else
  bad "the neutral refusal path did not run — every falsifiable assertion was skipped"
fi
printf '==> %d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
[ "$SKIP" -gt 0 ] && printf '==> %d skipped: the full macOS deploy sections; the plan/refusal and\n    verify-classification guarantees were asserted above on THIS platform.\n' "$SKIP"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
