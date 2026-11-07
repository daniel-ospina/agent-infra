#!/usr/bin/env bash
# tests/install-ci-runner-x64/run.sh — the adapter's contract, proven against a FAKE pool tool.
#
# Run: bash tests/install-ci-runner-x64/run.sh   (exits 0 when every assertion passes)
#
# ⛔ THIS SUITE LIVES UNDER `tests/*/run.sh`, NOT BESIDE THE FILE IT TESTS. It was written as
# `tools/install-ci-runner-x64.test.sh`, which is outside every `SUITE_GLOBS` pattern in
# `scripts/run-bash-shards.sh` (`scripts/**`, `tests/*/run.sh`, `pi-bootstrap/tests/*.sh`), so it was
# executed by NOTHING: the 22/22 in the PR body was real and unenforced on every future push, and a
# broken adapter could merge green. `tests/*/run.sh` is the repo's discovered convention, so the suite
# is now part of the sharded `bash-suites` lane with no edit to the runner. (It also stops tripping the
# #1484 guard, which refuses to execute `tools/*.test.sh` from a hub-rooted session in a worktree.)
#
# ⛔ NO REAL REGISTRATION IS EVER MADE HERE. `CI_RUNNER_POOL_TOOL` points at a fixture that records
# its argv and exits with a chosen code, so the properties that matter — "a guard refusal propagates
# as a refusal", "an existing slot is not added twice", "the slot NAME is the one the caller's
# `_next_free_slot` derives" and "the LAST line of the MERGED stream is the accounting" — are tested
# without a token, a network, or a live runner. A test that registers a real runner on the host it
# runs on is how this fleet got leaked launchd units and 26-hour orphan controllers (#3430).
#
# The invariants here are not stylistic: each case is a way the adapter can provision runners that
# `runner_autoscale.py` cannot count, or record a correct refusal as a failure — see the adapter's
# header for the four facts from the caller that each one pins.
set -uo pipefail

HERE=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd) || exit 1
SUT=$HERE/../../tools/install-ci-runner-x64.sh
TMP=$(mktemp -d "${TMPDIR:-/tmp}/install-ci-runner-x64.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT
pass=0 fail=0

# The host's own runner environment must not decide the outcome of a test.
unset RUNNER_ROOT RUNNER_AUTOSCALE_RUNNER_ROOT RUNNER_AUTOSCALE_BASE RUNNER_NAME_PREFIX

ok()   { pass=$((pass+1)); printf '  ok   %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf '  FAIL %s\n' "$1"; }
# check <label> <expected-rc> <actual-rc> [expected-substring] [haystack]
check() {
  local label=$1 want=$2 got=$3 sub=${4:-} hay=${5:-}
  if [ "$want" != "$got" ]; then bad "$label (rc want=$want got=$got)"; return; fi
  if [ -n "$sub" ] && ! grep -qF -- "$sub" <<<"$hay"; then
    bad "$label (missing '$sub' in: $(printf '%s' "$hay" | tr '\n' '|' | cut -c1-140))"; return
  fi
  ok "$label"
}

# fake_pool <rc> — a pool tool that logs its argv and exits rc, printing a reading/refusal line.
fake_pool() {
  local rc=$1 body=$TMP/fake-pool.sh
  cat > "$body" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls.log"
printf 'RUNNER_POOL_REPO=%s\n' "\${RUNNER_POOL_REPO:-}" >> "$TMP/pool-env.log"
printf 'fake: mem_floor_mb=3584 reading_mb=2210 %s\n' "\${FAKE_NOTE:-}"
exit $rc
EOF
  chmod +x "$body"
  printf '%s\n' "$body"
}

# fake_pool_racing <rc> — a pool tool that takes the name it was given, COMPLETES the install
# (creates `<root>/<name>/.runner`), logs its argv and then exits rc. This is the measured shape of
# "another pass took this slot while this one ran": the caller asked for an index that is now filled.
fake_pool_racing() {
  local rc=$1 body=$TMP/fake-pool-racing.sh
  cat > "$body" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls.log"
name=""
while [ \$# -gt 0 ]; do case "\$1" in --name) shift; name="\${1:-}" ;; esac; shift; done
[ -n "\$name" ] || { printf 'fake: no --name on argv\n' >&2; exit 99; }
mkdir -p "\$RUNNER_ROOT/\$name" && : > "\$RUNNER_ROOT/\$name/.runner"
printf 'name-unavailable name=%s (created by another actor)\n' "\$name" >&2
exit $rc
EOF
  chmod +x "$body"
  printf '%s\n' "$body"
}

# fake_pool_preclaimed <rc> — the pool's rc-4 PRE-CLAIM gate (`name-unavailable … already exists (a
# file, a symlink, or a directory without a .runner registration) — clear it or pick another name`).
# ⛔ It does NOT create anything: the wedge is the directory that was ALREADY there before the call, so
# the caller must create it first. (A fixture that creates it during the call models the RACE, not the
# wedge — the adapter separates them by whether the path existed before, and it should.)
fake_pool_preclaimed() {
  local rc=$1 body=$TMP/fake-pool-preclaimed.sh
  cat > "$body" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls.log"
name=""
while [ \$# -gt 0 ]; do case "\$1" in --name) shift; name="\${1:-}" ;; esac; shift; done
[ -n "\$name" ] || { printf 'fake: no --name on argv\n' >&2; exit 99; }
printf 'name-unavailable name=%s path=%s/\$name already exists (a file, a symlink, or a directory without a .runner registration) — clear it or pick another name\n' "\$name" "\$RUNNER_ROOT" >&2
exit $rc
EOF
  chmod +x "$body"
  printf '%s\n' "$body"
}

# fake_pool_registered_dead — the pool's OTHER rc-2 arm, quoted from `scripts/ci_runner_pool.sh::add`:
# `config.sh` wrote `.runner` (the registration EXISTS), then `start_listener` failed, so it prints
# `registered=1 listener=dead … run: restart --name …` and returns 2. "Nothing was attempted" and
# "nothing was added" are both FALSE about this state.
fake_pool_registered_dead() {
  local body=$TMP/fake-pool-regdead.sh
  cat > "$body" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls.log"
name=""
while [ \$# -gt 0 ]; do case "\$1" in --name) shift; name="\${1:-}" ;; esac; shift; done
[ -n "\$name" ] || { printf 'fake: no --name on argv\n' >&2; exit 99; }
mkdir -p "\$RUNNER_ROOT/\$name" && : > "\$RUNNER_ROOT/\$name/.runner"
printf 'registered=1 listener=dead name=%s dir=%s/\$name — the registration is in place; run: restart --name %s\n' "\$name" "\$RUNNER_ROOT" "\$name" >&2
exit 2
EOF
  chmod +x "$body"
  printf '%s\n' "$body"
}

# fake_pool_race — the pool's rc-4 mkdir-race arm (`… appeared while this add ran (another pass took
# it) — use restart`): the directory appears DURING the add and the peer may be registering it now.
fake_pool_race() {
  local body=$TMP/fake-pool-race.sh
  cat > "$body" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP/calls.log"
name=""
while [ \$# -gt 0 ]; do case "\$1" in --name) shift; name="\${1:-}" ;; esac; shift; done
[ -n "\$name" ] || { printf 'fake: no --name on argv\n' >&2; exit 99; }
mkdir -p "\$RUNNER_ROOT/\$name"
printf 'name-unavailable name=%s path=%s/\$name appeared while this add ran (another pass took it) — use restart\n' "\$name" "\$RUNNER_ROOT" >&2
exit 4
EOF
  chmod +x "$body"
  printf '%s\n' "$body"
}

: > "$TMP/calls.log"
# A correctly-configured box names the SAME root to both tools: `RUNNER_ROOT` is what the pool tool
# installs under, `RUNNER_AUTOSCALE_RUNNER_ROOT` is what the caller inventories. Cases 15 and 16 are
# the ones that make them disagree on purpose.
export RUNNER_ROOT=$TMP/root
export RUNNER_AUTOSCALE_RUNNER_ROOT=$TMP/root
mkdir -p "$RUNNER_ROOT"

# 1. --count required
out=$(bash "$SUT" 2>&1); rc=$?
check "missing --count is a usage error" 1 "$rc" "usage:" "$out"

# 2. leading-zero count is refused, not silently re-read as octal or as false
out=$(bash "$SUT" --count 08 --fallback auto 2>&1); rc=$?
check "leading-zero count -> refusal" 2 "$rc" "cannot-measure why=count-not-a-positive-integer" "$out"

# 3. a strategy other than auto is refused rather than ignored
out=$(bash "$SUT" --count 2 --fallback manual 2>&1); rc=$?
check "unsupported --fallback refused" 1 "$rc" "unsupported --fallback" "$out"

# 4. an unreadable pool tool is a REFUSAL (the original defect, in its smallest form)
out=$(CI_RUNNER_POOL_TOOL=$TMP/nope.sh bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "unreadable pool tool -> refusal naming the path" 2 "$rc" "why=pool-tool-unreadable" "$out"

# 5. the pool tool's rc=2 (cannot-measure / cannot-act) propagates as a REFUSAL
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 2) bash "$SUT" --count 2 --fallback auto 2>&1); rc=$?
check "pool cannot-measure (rc=2) propagates as a refusal" 2 "$rc" "guard-refused" "$out"

# 6. ⛔ THE POOL TOOL'S GATE VERDICTS ARE rc=3, NOT rc=2 (`REFUSED add … nothing added`: the memory
# floor and the core-aware ceiling — the COMMON verdict on a box already at its limit). Mapping only
# rc=2 recorded a correct refusal as a hard failure on every pass (#3469's shape).
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 3) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "pool gate REFUSAL (rc=3) propagates as a refusal" 2 "$rc" "guard-refused" "$out"
calls=$(wc -l < "$TMP/calls.log" | tr -d ' ')
check "refusal stops the loop (1 attempt, not 2)" 1 "$calls"

# 7. any other rc propagates verbatim — a real failure is never reported as a refusal
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 7) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "hard failure propagates its own rc" 7 "$rc" "rc=7" "$out"

# 8. slot 1 is the caller's BASE name — `_next_free_slot` numbers it `gh-runner-x64`, never
# `gh-runner-x64-1`, so a `-1` suffix leaves the caller's slot #1 permanently free.
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "success exit 0" 0 "$rc" "provisioned slot=1 name=gh-runner-x64 root=$RUNNER_ROOT added=1" "$out"
calls=$(tr '\n' '|' < "$TMP/calls.log")
check "slot 1 is requested under the base name" 0 0 "add --name gh-runner-x64|" "$calls"

# 9. ⛔ `--count N` IS A SLOT INDEX, NOT A TOTAL: the caller passes `_next_free_slot`, so ONE call is
# at most ONE addition. A cumulative "make 1..N exist" sweep puts several runners on a box whose
# per-step memory/disk re-read budgeted one.
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 3 --fallback auto 2>&1); rc=$?
check "slot 3 derived from the index" 0 "$rc" "name=gh-runner-x64-3 root=$RUNNER_ROOT added=1" "$out"
calls=$(tr '\n' '|' < "$TMP/calls.log")
check "slot 3 asks for exactly one name" 0 0 "add --name gh-runner-x64-3|" "$calls"
case "$calls" in *gh-runner-x64-1*|*gh-runner-x64-2*) bad "a slot index swept lower slots into the same call";; *) ok "one call = one addition";; esac

# 10. ⛔ THE PASS RECORD IS THE LAST LINE OF THE *MERGED* STREAM (`_run` concatenates stdout then
# stderr), so the accounting must be last and stderr must be silent on the success path.
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 2 --fallback auto 2>&1)
lastline=$(printf '%s\n' "$out" | tail -1)
case "$lastline" in
  "provisioned slot=2 name=gh-runner-x64-2 root=$RUNNER_ROOT added=1"*) ok "the merged last line is the accounting";;
  *) bad "the merged last line is not the accounting: $(printf '%s' "$lastline" | cut -c1-120)";;
esac

# 11. IDEMPOTENCY: an existing install is skipped, not added a second time (the #9639 over-fill)
mkdir -p "$RUNNER_ROOT/gh-runner-x64"; : > "$RUNNER_ROOT/gh-runner-x64/.runner"
: > "$TMP/calls.log"
# ⛔ STDERR IS CAPTURED SEPARATELY, NOT MERGED. The caller records the LAST line of the MERGED
# stdout+stderr stream, so a stray stderr line on a SUCCESS path silently replaces the accounting —
# asserting a substring of a merged stream cannot see it. Every success path is pinned this way.
: > "$TMP/err11.txt"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>"$TMP/err11.txt"); rc=$?
check "existing slot skipped, still exit 0" 0 "$rc" "provisioned slot=1 name=gh-runner-x64 root=$RUNNER_ROOT added=0 skipped=1" "$out"
if [ -s "$TMP/err11.txt" ]; then
  bad "the idempotent-skip success path writes nothing to stderr: $(cut -c1-120 "$TMP/err11.txt")"
else
  ok "the idempotent-skip success path writes nothing to stderr"
fi
calls=$(wc -l < "$TMP/calls.log" | tr -d ' ')
check "no add beside an existing install" 0 "$calls"

# 12. --dry-run reaches the pool tool and does not claim to have provisioned
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 2 --fallback auto --dry-run 2>&1); rc=$?
calls=$(tr '\n' '|' < "$TMP/calls.log")
check "--dry-run is passed through" 0 0 "add --name gh-runner-x64-2 --dry-run|" "$calls"
check "a dry run does not report a provision" 0 "$rc" "would-provision slot=2" "$out"

# 13. a base OUTSIDE the root is uncountable by `discover()` — refused, not installed blind
out=$(RUNNER_AUTOSCALE_BASE=$TMP/elsewhere/gh-runner-x64 CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "base outside the caller's root -> refusal" 2 "$rc" "why=base-outside-root" "$out"

# 14. a base that does not start with `gh-runner` is invisible to `discover()` — refused
out=$(RUNNER_AUTOSCALE_BASE=$RUNNER_ROOT/pi-runner-x64 CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "base not discoverable as gh-runner* -> refusal" 2 "$rc" "why=base-not-discoverable" "$out"

# 15. the root FOLLOWS the caller when only the caller's knob is set (`provision()` passes it as
# `RUNNER_AUTOSCALE_RUNNER_ROOT` in the child env — it used to pass no root at all)
out=$(env -u RUNNER_ROOT RUNNER_AUTOSCALE_RUNNER_ROOT=$TMP/root2 CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "root follows RUNNER_AUTOSCALE_RUNNER_ROOT" 0 "$rc" "root=$TMP/root2 added=1" "$out"

# 16. two different roots is a box that provisions what the caller cannot count — refused
out=$(RUNNER_ROOT=$TMP/root RUNNER_AUTOSCALE_RUNNER_ROOT=$TMP/other CI_RUNNER_POOL_TOOL=$(fake_pool 0) bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "disagreeing roots -> refusal" 2 "$rc" "why=root-disagreement" "$out"

# 17. ⛔ rc 4 WITH the slot now holding `.runner` IS SUCCESS — the box converged, and reporting it as
# a failure is the rc-3 defect one code over. Measured before this case: the pool created
# `<root>/gh-runner-x64-2/.runner` and exited 4, and the pass recorded action-failed although the
# requested slot existed. Two passes adding the same index is a real condition here (the caller takes
# no inter-pass lock and its own docs note passes racing).
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool_racing 4) bash "$SUT" --count 4 --fallback auto 2>"$TMP/err17.txt"); rc=$?
check "rc 4 with the slot now FILLED is a skip, not a failure" 0 "$rc" \
  "provisioned slot=4 name=gh-runner-x64-4 root=$RUNNER_ROOT added=0 skipped=1" "$out"
if [ -s "$TMP/err17.txt" ]; then
  bad "rc 4 convergence writes nothing to stderr (the pass record is the merged last line)"
else
  ok "rc 4 convergence writes nothing to stderr (the pass record is the merged last line)"
fi
if [ -e "$RUNNER_ROOT/gh-runner-x64-4/.runner" ]; then
  ok "precondition: the raced slot really carries .runner"
else
  bad "precondition: the raced slot really carries .runner"
fi

# 18. ⛔ BUT rc 4 WITH NO `.runner` ON A PATH THAT WAS ALREADY THERE IS A WEDGE, NOT A FAILURE:
# `_next_free_slot` tests only `.runner`, so it asks for this same index forever while `add`/`reclaim`
# refuse the path and `reconcile` never enumerates it. Nothing repairs it automatically, so it is
# reported as a REFUSAL naming the path to clear (exit 2 -> ProvisionerRefused) instead of an
# action-failed every ten minutes. The leftover exists BEFORE the call — that is the fact separating
# it from the race in case 20, and creating it here is the whole arrangement.
mkdir -p "$RUNNER_ROOT/gh-runner-x64-5"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool_preclaimed 4) bash "$SUT" --count 5 --fallback auto 2>&1); rc=$?
check "rc 4 on a PRE-EXISTING path without .runner is a REFUSAL" 2 "$rc" "guard-refused" "$out"
check "…naming both possible causes, not just one" 0 0 "stale leftover from an interrupted add or a peer's add" "$out"
check "…and telling the operator to retry, not to delete" 0 0 "retry on the next pass" "$out"
case "$out" in
  *"rm -rf"*) bad "the pre-existing-path refusal must NEVER prescribe rm -rf — a peer's in-flight add holds these exact bytes";;
  *) ok "the pre-existing-path refusal never prescribes rm -rf";;
esac

# 18b. ⛔ A DANGLING `.runner` SYMLINK IS THE ONE STATE WHERE THE TWO TOOLS DISAGREE ABOUT THE SAME
# BYTES: the pool's occupancy test is `[ -e ] || [ -L ]` (answers `already registered — use restart`)
# while the caller's is `Path(...).exists()`, which follows the link and answers FREE. Exiting 0 with
# `skipped` would hide a slot that never counts — a false PASS.
W="$RUNNER_ROOT/gh-runner-x64-8"; mkdir -p "$W"; ln -s /nonexistent/config.json "$W/.runner"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool_preclaimed 4) bash "$SUT" --count 8 --fallback auto 2>&1); rc=$?
check "a dangling .runner symlink is a REFUSAL, not a silent skip" 2 "$rc" "SYMLINK with no target" "$out"
check "…naming the pool/caller disagreement" 0 0 "reports the slot REGISTERED" "$out"
case "$out" in
  *added=1*|*added=0*) bad "a disagreement about occupancy never claims a provision";;
  *) ok "a disagreement about occupancy never claims a provision";;
esac
rm -f "$W/.runner"
case "$out" in
  *added=1*) bad "a wedged slot never claims to have provisioned";;
  *) ok "a wedged slot never claims to have provisioned";;
esac

# 19. ⛔ rc 2 IS NOT ONLY "nothing attempted". The pool returns 2 from `add` in TWO states, and one of
# them is a SUCCESS with a defect: after `config.sh` wrote `.runner` the registration EXISTS and only
# `start_listener` failed (`registered=1 listener=dead … run: restart --name …`,
# scripts/ci_runner_pool.sh::add). Mapping that to a refusal made this file print "nothing further
# attempted" and the caller record `nothing was added` about a registration that is in the pool.
: > "$TMP/calls.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool_registered_dead) bash "$SUT" --count 6 --fallback auto 2>"$TMP/err_reg.txt"); rc=$?
check "rc 2 WITH .runner is a registration, not a refusal" 0 "$rc" \
  "provisioned slot=6 name=gh-runner-x64-6 root=$RUNNER_ROOT added=1 skipped=0 listener=dead" "$out"
check "…and the dead listener the pool names is in the record" 0 0 "listener=dead" "$out"
if [ -s "$TMP/err_reg.txt" ]; then
  bad "the rc-2 registration success path writes nothing to stderr: $(cut -c1-120 "$TMP/err_reg.txt")"
else
  ok "the rc-2 registration success path writes nothing to stderr"
fi

# 20. ⛔ rc 4 WITH NO `.runner` IS TWO FACTS, AND THE REMEDY DIFFERS. Both are refusals (exit 2), but a
# path that PRE-EXISTED is a wedge a human must clear, while a path that APPEARED during the call is a
# peer that won the race and may be registering it right now. Printing `rm -rf` for the race would tell
# an operator to delete a registration in progress.
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool_race) bash "$SUT" --count 7 --fallback auto 2>&1); rc=$?
check "rc 4 race (path appeared during the call) is a refusal" 2 "$rc" "guard-refused" "$out"
check "…naming the RACE" 0 0 "another pass took this slot while this add ran" "$out"
check "…and offering the pool's own restart" 0 0 "restart --name gh-runner-x64-7" "$out"
case "$out" in
  *"rm -rf"*) bad "the race must NEVER prescribe rm -rf over a peer's in-progress registration";;
  *) ok "the race does not prescribe rm -rf over a peer's in-progress registration";;
esac

# 21. ⛔ THE ADAPTER PRESCRIBES `rm -rf` NOWHERE, AND THAT IS A PINNED PROPERTY, NOT A STYLE CHOICE.
# `ci_runner_pool.sh::add` creates the dir, copies the template, runs `config.sh` and only THEN writes
# `.runner`, so a peer's in-flight add is byte-identical to a stale leftover. A refusal that told an
# operator to delete the path could delete a live registration.
# ⛔ THE CHECK IS ON OUTPUT LINES, NOT ON THE FILE TEXT: the header and this very comment DISCUSS the
# ban (`rm -rf` appears in prose explaining why it is never prescribed), so a whole-file grep would
# red on its own explanation. What matters is whether any MESSAGE the tool prints carries it.
if grep -nE '^[[:space:]]*(err|printf)[^#]*rm -rf' "$SUT"; then
  bad "an adapter MESSAGE prescribes rm -rf — it must never tell an operator to delete a path it did not create"
else
  ok "no adapter message prescribes rm -rf"
fi

# 22. ⛔ THE REGISTRATION TARGET IS THE CALLER'S, NOT THE POOL TOOL'S DEFAULT (agent-infra#3469 review P2).
# `ci_runner_pool.sh:261` resolves `POOL_REPO="${RUNNER_POOL_REPO:-daniel-ospina/tortoise}"` and uses it for
# BOTH the token scope (`:1659`) and the registration URL (`:1724`). The caller exports its own seam
# (`RUNNER_AUTOSCALE_REPO`, `runner_autoscale.py:3969`); the JOIN is what translates it, because teaching the
# caller the pool tool's private variable name is the second coupling this file exists to prevent. Without
# the translation a repointed box registered into tortoise while the caller's repo-agnostic `_live()` counted
# the runner — `verdict=converged`, exit 0, and zero capacity for the repo it was asked to converge.
: > "$TMP/pool-env.log"
out=$(RUNNER_AUTOSCALE_REPO=o/other CI_RUNNER_POOL_TOOL=$(fake_pool 0) \
      env -u RUNNER_ROOT -u RUNNER_POOL_REPO RUNNER_AUTOSCALE_RUNNER_ROOT="$TMP/r22" bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "a call carrying the caller's repo still provisions" 0 "$rc" "" "$out"
check "…and the pool child is told THAT repo" 0 0 "RUNNER_POOL_REPO=o/other" "$(cat "$TMP/pool-env.log")"
: > "$TMP/pool-env.log"
out=$(CI_RUNNER_POOL_TOOL=$(fake_pool 0) \
      env -u RUNNER_ROOT -u RUNNER_POOL_REPO -u RUNNER_AUTOSCALE_REPO RUNNER_AUTOSCALE_RUNNER_ROOT="$TMP/r22b" bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "a call with NO caller repo still provisions on the pool tool's own default" 0 "$rc" "" "$out"
check "…and the adapter invents no repo of its own" 0 0 "RUNNER_POOL_REPO=" "$(cat "$TMP/pool-env.log")"
# ⛔ AND TWO DECLARED REPOS THAT DISAGREE ARE REFUSED, NOT ARBITRATED — the same direction the `RUNNER_ROOT`
# guard above takes, for the same reason: picking a side is how the false PASS gets written.
out=$(RUNNER_AUTOSCALE_REPO=o/other RUNNER_POOL_REPO=o/third CI_RUNNER_POOL_TOOL=$(fake_pool 0) \
      env -u RUNNER_ROOT RUNNER_AUTOSCALE_RUNNER_ROOT="$TMP/r22c" bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "two disagreeing repos are a refusal (rc 2)" 2 "$rc" "repo-disagreement" "$out"
check "…naming both values" 0 0 "RUNNER_POOL_REPO=o/third RUNNER_AUTOSCALE_REPO=o/other" "$out"
out=$(RUNNER_AUTOSCALE_REPO=o/same RUNNER_POOL_REPO=o/same CI_RUNNER_POOL_TOOL=$(fake_pool 0) \
      env -u RUNNER_ROOT RUNNER_AUTOSCALE_RUNNER_ROOT="$TMP/r22d" bash "$SUT" --count 1 --fallback auto 2>&1); rc=$?
check "…while two AGREEING repos are not a false block" 0 "$rc" "" "$out"

printf '\n%s\n' "install-ci-runner-x64: pass=$pass fail=$fail"
[ "$fail" -eq 0 ] || exit 1
