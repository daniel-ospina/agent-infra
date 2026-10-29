#!/usr/bin/env bash
# tests/git-fixture-host-neutral/run.sh — agent-infra#2581: a fixture's verdict must not be a
# function of the BOX.
#
# THE DEFECT (why this exists)
# ----------------------------
#   `origin/main` at 9b80ee4c was red on its own post-merge leg (`extension-tests / unit-test`,
#   check-run 120643122366) with exactly two annotations —
#   `extensions/shared/test-branch-ownership.mjs` and
#   `extensions/main-worktree-guard/test-module-load.mjs` — while both suites were GREEN on a
#   developer box whose EFFECTIVE git config supplied `init.defaultBranch=main`. Both fixtures
#   build an EMPTY bare origin and `git clone` it; a clone of an empty repo takes its branch from
#   `init.defaultBranch` in that config, so where it is unset (a CI runner, a fresh cell) git names
#   it `master` and the fixture's own `git push origin main` dies with
#   `error: src refspec main does not match any` — a message that names the refspec, never the
#   cause.
#   ⚠️ WHICH CHANNEL SUPPLIES IT DIFFERS, and that is why this shard neutralises all of them:
#   `test-branch-ownership.mjs` reads the GLOBAL channel (`~/.gitconfig`), while
#   `test-module-load.mjs` replaces `process.env.HOME` with a throwaway dir before it loads, so a
#   `~/.gitconfig` never reaches it — measured on the unfixed tree, a temp HOME carrying
#   `init.defaultBranch=main` leaves it at 108 passed / 1 failed, green only when the value comes
#   from the system/ambient channel.
#   The identity is NOT involved (measured): with user.email/user.name absent and
#   init.defaultBranch=main present, both suites report 360/0 and 131/0.
#
# THE FIX THIS SUITE GUARDS
# -------------------------
#   Each fixture now names its own default branch at creation
#   (`git init -q --bare -b main <bare>`, the repo-wide idiom — 15+ other fixtures do the same), so
#   every clone of that origin lands on `main` whatever the box carries. No global config is
#   written and no developer machine needs configuring.
#
# WHAT THIS SUITE PINS
# --------------------
#   1. SEAM — the sanitised child environment provably reads NO git config, on BOTH channels the
#      dependency could arrive through: (a) the global file is absent AND the probe fails closed
#      when it cannot be read (a misspelled GIT_CONFIG_GLOBAL on a configured dev box is exactly
#      that vacuity), and (b) an all-channels listing taken from outside any repo is empty (a
#      system/ambient leak). Without these arms the runs below could be green because
#      neutralisation silently did nothing, and the dependency would survive every green run.
#   2. MODEL — an empty bare repo created with `-b main` clones onto `main` in that environment:
#      the deterministic property the fixtures now rest on, asserted directly rather than only
#      through them.
#   3. FIXTURE — the two suites from the red run must exit 0 AND print their own aggregate line.
#      Exit status alone is not enough: a suite that CRASHES prints no aggregate line at all, which
#      is the #2188 shape that made a red main uncertifiable.
#
# WHY A BASH SHARD AND NOT A WORKFLOW STEP — `ci.yml`, `node-ci.yml` and `ci-main.yml` are
#   BYTE-LOCKED (`scripts/check-workflow-lock.mjs` LOCKED_FILES): wiring a step there re-cuts the
#   last-writer-wins `scripts/workflow-lock.json`, which conflicts with every concurrent workflow
#   PR, and a `ci-main.yml` line runs POST-MERGE only — i.e. after the merge that reddens main.
#   This file is in `scripts/run-bash-shards.sh`, the single shard list BOTH lanes execute
#   (#1369), so the assertion runs on the PR and after it. One run site, no locked-file edit.
#
# ADD A SUITE HERE when it starts shelling out `git commit`/`git push` in a temp repo. It must
#   print an aggregate line shaped `<n> passed, <m> failed` (arm 3 reads
#   `[1-9][0-9]* passed, 0 failed` — a ZERO count does NOT satisfy it: a suite that runs no
#   assertions has not passed, it has stopped testing, and exit status alone cannot see that).
#   A suite that reports differently fails arm 3 LOUDLY rather than passing silently — adjust the
#   arm when you add such a suite.
#
# NOTE ON STYLE: every capture is `cmd >file` + `cat file`, never `OUT="$(… git …)"` — the
#   main-worktree-guard content walker (#1484) reads a git invocation inside a command substitution
#   as an unsanctioned git operation and refuses to run the script.

set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || exit 1

checks=0
failures=0
pass() { checks=$((checks + 1)); echo "   ✅ $1"; }
fail() { checks=$((checks + 1)); echo "   ❌ $1"; failures=$((failures + 1)); }
indent() { sed -n "$1" | sed 's/^/     | /'; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
OUT="$TMP/out.txt"
mkdir -p "$TMP/home"

# No global config, no system config, no init template, and a HOME with no `.gitconfig` to fall
# back on. `GIT_CONFIG_NOSYSTEM=1` and `GIT_CONFIG_SYSTEM=/dev/null` are deliberately redundant: a
# future git that honours only one of them must not silently re-open the seam.
bare_env() {
  env HOME="$TMP/home" \
      GIT_CONFIG_GLOBAL=/dev/null \
      GIT_CONFIG_SYSTEM=/dev/null \
      GIT_CONFIG_NOSYSTEM=1 \
      "$@"
}

echo "== 1. the sanitised environment reads no git config, on either channel =="
bare_env git config --global --list >"$OUT" 2>&1
seam_rc=$?
if [ "$seam_rc" -ne 0 ]; then
  # Reading the (empty) global file failed — e.g. the path is relative, or the var is misspelled
  # so git falls back to a HOME that does not exist. Fail closed and NAME that.
  fail "the child cannot read its global config file at all (rc=$seam_rc) — the neutralisation is not wired, so every assertion below would be vacuous (first lines:)"
  indent '1,4p' <"$OUT"
elif [ -s "$OUT" ]; then
  fail "the child environment STILL reads a global git config file — the neutralisation is not wired, so every assertion below would be vacuous (first lines:)"
  indent '1,4p' <"$OUT"
else
  pass "the global channel is empty and readable (an unwired seam fails closed, not green)"
fi
# The second channel: a listing of EVERY source, taken from outside any repo (a repo-local file
# would otherwise be expected output). Any line here is a config the child inherited.
( cd "$TMP" && bare_env git config --list --show-origin ) >"$OUT" 2>&1
if [ -s "$OUT" ]; then
  fail "the child environment inherits git config from a SYSTEM/AMBIENT source — the suites below would be reading the box (first lines:)"
  indent '1,4p' <"$OUT"
else
  pass "no git config of any origin is visible to the child"
fi

echo "== 2. an empty bare repo created with -b main clones onto main =="
git init -q --bare -b main "$TMP/model.git"
bare_env git clone -q "$TMP/model.git" "$TMP/model-clone" >"$OUT" 2>&1
bare_env git -C "$TMP/model-clone" symbolic-ref --short HEAD >"$OUT" 2>&1
model_branch="$(cat "$OUT")"
if [ "$model_branch" = "main" ]; then
  pass "a clone of an empty bare origin lands on 'main' with no host config"
else
  fail "a clone of an empty bare origin landed on '${model_branch:-<none>}', not 'main' — the fixture's own pin is not deterministic (#2581)"
fi

echo "== 3. the two suites from the red run, in that environment =="
for t in extensions/shared/test-branch-ownership.mjs \
         extensions/main-worktree-guard/test-module-load.mjs; do
  bare_env node "$t" >"$OUT" 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    fail "$t exited $rc with no git config at all — it depends on the BOX's git config again (#2581); last lines:"
    tail -n 6 "$OUT" | sed 's/^/     | /'
  elif ! grep -qE '[1-9][0-9]* passed, 0 failed' "$OUT"; then
    fail "$t exited 0 but printed no aggregate '<n> passed, 0 failed' line with n>0 — a suite that cannot report, or that ran NO assertions, is not a pass (#2188)"
  else
    pass "$t: $(grep -E '[1-9][0-9]* passed, 0 failed' "$OUT" | tail -n 1 | sed 's/^[✅ ]*//')"
  fi
done

echo
if [ "$failures" -eq 0 ]; then
  echo "✅ git-fixture-host-neutral: $checks passed, 0 failed"
  exit 0
fi
echo "❌ git-fixture-host-neutral: $((checks - failures)) passed, $failures failed"
exit 1
