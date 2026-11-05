#!/bin/bash
# Pin the merge-slot accounting of auto-rail.sh. What is under test is EXTRACTED FROM THE SCRIPT ITSELF,
# never restated here: the counter, the defer predicate, the call site's shape, the aggregate's
# derivation, the attribution, the cooldown, the ledger, the launch and the lock. A copy of a rule in
# this file (e.g. a literal `MAX_TOTAL=16`, or an `if [ total -ge MAX ]` standing in for the call site)
# pins nothing: the shipped line could then be broken or disarmed with the suite still green.
#
# ⛔ WHAT EACH PIN CAN AND CANNOT SEE — stated, because a test that overclaims is a false record:
#   * DRIVEN (behaviour): `rail_rows` (and therefore `rails_for_repo`), `rails_should_defer`,
#     `candidate_deferred`'s shape, `max_total_for`, `rail_already_running`, `rail_says_skip`,
#     `denied` (the DENY key), `cooldown_for` (which cooldown applies), `forget_tried` (the rollback),
#     `launch_rail` (verified launch + rollback), `lock_holder_is_live` / `acquire_lock` (the lock's
#     three answers and the reclaim), `report_search` (a failed search is a verdict, not an empty
#     queue) and the shipped `python3` candidate search itself, run from its extracted heredoc against
#     a stubbed `gh`. Mutating any of them reddens this suite.
#   * GREPPED (text, and declared as text): the pass LOOP's invocation of `candidate_deferred`, of
#     `rail_already_running`/`rail_says_skip`, and the `2>> "$LOG"` on the search. The loop runs
#     `while :` around a live `gh`/`ps`/supervisor pass, so driving it here would mean stub-driving the
#     whole actuator; those lines are pinned by whole-literal comparison at "the loop's own call"
#     below, so a reordering or an edit inside either line reddens. What they cannot see is a line
#     becoming UNREACHABLE (moved below a `continue`, or wrapped in `if false`) — that class is not
#     pinned by anything here, and saying so is the point of this paragraph.
#   * NOT PINNED AT ALL, declared rather than left to be discovered: the loop's HEAD-READ guard, the
#     ordering of `cooldown_for` against the head read, and the aggregate `REFUSED` at `MAX_TOTAL=0`
#     being reached before the rail-hub check. All are loop/startup sequencing, and driving them means
#     stub-driving the actuator; they are guarded in the SUT and verified by reading, not by this suite.
#
# ⛔ "FAILS BEFORE THE FIX" MEANS SOMETHING SPECIFIC HERE, and it is not "it ran an older tree": this
# file is ADDED by the same change, so there is no pre-fix tree. Each arm that states a defect was
# PROVEN to redden by MUTATING THE SHIPPED LINE back to the defect and re-running (see the commit
# messages); the arms that name the OLD rule (`total >= MAX`) do so as a hand-written CONTRAST for the
# reader, and they are labelled as contrast — they are not the pre-fix code and never were.
#
# The fixture is `ps -eo args=` output from this box on 2026-11-01 at ~17:11Z, captured immediately
# BEFORE the actuator restart at 17:12:02Z cleared the population (the restart is the collateral
# recorded in agent-infra#3224; `rails_live` reads 0 at 17:12:08Z and that is the same table, emptied).
# It is 8 rows: 7 on agent-infra — six carrying `--repo daniel-ospina/agent-infra`, one of them the
# duplicate launch of #3136, PLUS another lane's worktree dry-run attributed by its script path — and 1
# on tortoise.
# ⛔ THAT PATH-ONLY ROW NOW READS `unattributed`, AND THAT IS THE FIX, NOT A REGRESSION (review round 5,
# P0). Its path is `/Users/danielospina/Documents/GitHub/agent-infra/...`, which names a DIRECTORY called
# `agent-infra` and no owner: on this box that directory is a clone whose `origin` resolves the owner, so
# the live actuator attributes it; in THIS suite the path does not exist, so there is no clone to ask and
# the honest answer is UNKNOWN — a bare directory name is exactly the evidence that produced the
# basename defect. Path attribution is pinned positively, against a REAL temp clone with a remote, in
# "THE IDENTITY IS owner/name" below.
set -u
HERE=$(dirname "$0")   # the SCRIPT under test: the tracked copy beside this file
SUT=${AUTO_RAIL_SCRIPT:-$HERE/auto-rail.sh}

# ── the shipped functions, extracted (the multi-line ones run to the first column-0 `}`) ──────────────
# One literal extraction per function: a generic `${1}`-building wrapper puts a `$` inside a word that
# also contains `/`, and the framework's worktree-discard gate reads that as an unresolvable script path
# and refuses to run the suite AT ALL (measured round 5: this suite was unrunnable from an agent shell).
eval "$(sed -n '/^rail_rows() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^rails_for_repo() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^rails_should_defer() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^candidate_deferred() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^max_total_for() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^rail_already_running() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^rail_says_skip() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^denied() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^cooldown_for() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^forget_tried() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^launch_rail() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^lock_holder_is_live() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^acquire_lock() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^report_search() {/,/^}$/p' "$SUT")"
for _fn in rail_rows rails_for_repo rails_should_defer candidate_deferred max_total_for \
           rail_already_running rail_says_skip denied cooldown_for forget_tried launch_rail \
           lock_holder_is_live acquire_lock report_search; do
  command -v "$_fn" >/dev/null || { echo "FATAL: $_fn not found in $SUT"; exit 2; }
done
# ⛔ `rails_should_defer` calls `log_line`, which the SCRIPT defines and this file does not — so without
# a stub the fail-closed diagnostic resolves to /usr/bin/say (macOS text-to-speech) and is SPOKEN instead
# of printed, a silent dependency on an unrelated system binary (measured, round 5). The helper is named
# `log_line`, NOT `say`, because `tests/no-tts/run.sh` refuses any shipped script that defines a `say`
# function (#2910) — on this box `say` is a real binary, so a call whose definition did not travel is
# spoken and nothing fails. It stays a FILE writer so the arms below can read the line they assert on.
log_line() { printf '%s\n' "$*" >> "$LOG"; }
LOG=$(mktemp)
LOCK=$(mktemp -d)/lock
TRIED=$(mktemp)
COOLDOWN_S=21600
COOLDOWN_TRANSIENT_S=900
LOCK_AGE_GRACE=120
LAUNCH_VERIFY_S=1
MAX=8
MAX_TOTAL=16
DENY=""
REPOS="daniel-ospina/tortoise daniel-ospina/agent-infra"

TABLE=""
ps() { printf '%s\n' "$TABLE"; }

fail=0
bad() { echo "FAIL: $*"; fail=1; }

# ══ THE CAPTURED POPULATION ═══════════════════════════════════════════════════════════════════════════
TABLE="$(cat <<'ROWS'
bash /Users/danielospina/Documents/GitHub/agent-infra/.worktrees/rail-exit-after-verdict/scripts/admin-merge.sh 42 --main-runs 10 --dry-run
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3054 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3055 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3057 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3136 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3136 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 3212 --repo daniel-ospina/agent-infra --any-workflow
bash /Users/danielospina/rail-hub/scripts/admin-merge.sh 10500 --repo daniel-ospina/tortoise
ROWS
)"
read -r t_own t_total t_unk <<< "$(rails_for_repo daniel-ospina/tortoise $REPOS)"
read -r a_own a_total a_unk <<< "$(rails_for_repo daniel-ospina/agent-infra $REPOS)"
printf 'captured table: tortoise=%s/%s/%s agent-infra=%s/%s/%s (own/total/unknown)\n' \
  "$t_own" "$t_total" "$t_unk" "$a_own" "$a_total" "$a_unk"

# The partition: every rail lands on exactly one repo or the unknown bucket.
[ "$t_total" -eq 8 ] || bad "total $t_total != 8"
[ "$t_own" -eq 1 ]   || bad "tortoise own $t_own != 1"
[ "$a_own" -eq 6 ]   || bad "agent-infra own $a_own != 6 (five --repo rows + the #3136 duplicate)"
[ "$a_unk" -eq 1 ]   || bad "agent-infra unknown $a_unk != 1 (the path-only dry-run: a directory named agent-infra, no owner, no clone here to ask)"
[ $(( t_own + a_own + t_unk )) -eq "$t_total" ] || bad "the three buckets do not partition the table"

# ⛔ THE DEFECT AS A DECISION, through the SHIPPED PREDICATE. On this table the OLD rule (`total >= MAX`,
# spelled out here as the contrast the fix is measured against — NOT as a stand-in for the call site,
# which is driven below) defers tortoise; the shipped rule must not.
MAX_TOTAL=16 MAX=8
if [ "$t_total" -ge 8 ]; then echo "old rule (total>=MAX) for a tortoise candidate: DEFER (contrast)"; else bad "fixture no longer reproduces the defect"; fi
if rails_should_defer daniel-ospina/tortoise $REPOS; then bad "new rule DEFERS tortoise on this table"
else echo "new rule (per repo) for a tortoise candidate: LAUNCH"; fi

# ⛔ THE CALL SITE, DRIVEN — the wrapper's SHAPE, and the argument-mangling class (dropping the
# population inside it, or forwarding it wrongly) reddens here. 8 rails on the OTHER repo must not shut
# tortoise's queue, and the same table with the population dropped must DEFER, which is what proves the
# population argument is load-bearing rather than decorative.
MAX_TOTAL=16 MAX=8
TABLE="$(for i in 1 2 3 4 5 6 7 8; do echo "bash /r/scripts/admin-merge.sh $i --repo daniel-ospina/agent-infra"; done)"
candidate_deferred daniel-ospina/tortoise $REPOS && bad "8 rails on the OTHER repo deferred tortoise's candidate — that is the starvation this PR fixes"
candidate_deferred daniel-ospina/tortoise || bad "with the population dropped these rails must read as UNKNOWN and defer — if they do not, this assertion no longer proves the argument is load-bearing"

# ══ THE IDENTITY IS `owner/name`, NOT THE BASENAME (review round 5 P0) ════════════════════════════════
# ⛔ THE PROBE THAT PROVES IT: 8 rails launched on `--repo premise-labs/agent-infra` — a DIFFERENT repo
# that merely shares a basename — used to read as `8 8 0` own/total/unknown for
# `daniel-ospina/agent-infra`, because both attribution sites did `.split("/")[-1]`. Two measured
# consequences, and this block pins BOTH:
#   * for the OTHER driven repo they read as neither own nor unknown (`0 8 0`): 8 live rails, and its
#     counter said nothing was running — a FAIL-OPEN launch, asserted as a DECISION below;
#   * for THIS repo the log claimed `rails_on_repo=8` about another org's queue.
TABLE="$(for i in 1 2 3 4 5 6 7 8; do echo "bash /r/scripts/admin-merge.sh $i --repo premise-labs/agent-infra"; done)"
read -r o_own o_total o_unk <<< "$(rails_for_repo daniel-ospina/agent-infra $REPOS)"
[ "$o_own" -eq 0 ] || bad "another org's same-named repo must NOT be counted on this repo as own (own=$o_own) — that is the basename defect"
[ "$o_unk" -eq 8 ] || bad "another org's same-named repo must be UNKNOWN load (unk=$o_unk)"
if candidate_deferred daniel-ospina/tortoise $REPOS; then echo "8 rails on another org's agent-infra defer a tortoise candidate: DEFER (fail-closed, correct)"
else bad "8 rails on another org's same-named repo left tortoise's counter at 0 own / 0 unknown and LAUNCHED — the fail-open this arm exists for"; fi

# A fork path with no `--repo` (the form `/opt/forks/agent-infra/scripts/admin-merge.sh 4`): the
# directory is named agent-infra, nothing says whose, and there is no clone here to ask. UNKNOWN.
TABLE="bash /opt/forks/agent-infra/scripts/admin-merge.sh 4 --any-workflow"
read -r f_own _f_total f_unk <<< "$(rails_for_repo daniel-ospina/agent-infra $REPOS)"
[ "$f_own" -eq 0 ] && [ "$f_unk" -eq 1 ] || bad "a path whose only evidence is a directory basename must be UNKNOWN (own=$f_own unk=$f_unk)"

# ⛔ PATH ATTRIBUTION IS EARNED FROM THE CLONE, not from the directory name: a checkout called
# `some-checkout` whose `origin` is daniel-ospina/tortoise is TORTOISE's rail. This is the arm that makes
# the path rule owner-aware instead of name-aware, and it needs a REAL repository to mean anything.
_gitroot=$(mktemp -d); mkdir -p "$_gitroot/some-checkout/scripts"
git -C "$_gitroot/some-checkout" init -q 2>/dev/null
git -C "$_gitroot/some-checkout" remote add origin https://github.com/daniel-ospina/tortoise.git
_clone_path="$_gitroot/some-checkout/scripts/admin-merge.sh"
TABLE=$(printf 'bash %s 10500' "$_clone_path")
read -r c_t_own _c_total _c_unk <<< "$(rails_for_repo daniel-ospina/tortoise $REPOS)"
read -r c_a_own _c2 _c3 <<< "$(rails_for_repo daniel-ospina/agent-infra $REPOS)"
[ "$c_t_own" -eq 1 ] && [ "$c_a_own" -eq 0 ] \
  || bad "a clone whose ORIGIN is daniel-ospina/tortoise must be tortoise's rail even though its directory is named some-checkout (tortoise=$c_t_own agent-infra=$c_a_own)"
# …and an `owner/name` path segment is accepted only when it names a DRIVEN repo.
TABLE="bash /opt/forks/daniel-ospina/agent-infra/scripts/admin-merge.sh 7"
read -r q_own _q_total _q_unk <<< "$(rails_for_repo daniel-ospina/agent-infra $REPOS)"
[ "$q_own" -eq 1 ] || bad "an owner-qualified path segment naming THIS repo must attribute (own=$q_own)"
TABLE="bash /opt/forks/premise-labs/agent-infra/scripts/admin-merge.sh 7"
read -r r_own _r_total r_unk <<< "$(rails_for_repo daniel-ospina/agent-infra $REPOS)"
[ "$r_own" -eq 0 ] && [ "$r_unk" -eq 1 ] || bad "an owner-qualified path naming ANOTHER org must stay unknown (own=$r_own unk=$r_unk)"
# A bare `--repo agent-infra` cannot name an owner, so it is UNKNOWN rather than assumed to be ours.
TABLE="bash /r/scripts/admin-merge.sh 7 --repo agent-infra"
read -r b_own _b_total b_unk <<< "$(rails_for_repo daniel-ospina/agent-infra $REPOS)"
[ "$b_own" -eq 0 ] && [ "$b_unk" -eq 1 ] || bad "a --repo with no owner must be UNKNOWN (own=$b_own unk=$b_unk)"
rm -rf "$_gitroot"

# ══ THE LOOP'S OWN CALL — TEXT assertions, labelled as text ══════════════════════════════════════════
loop_call=$(sed -n 's/^[[:space:]]*if candidate_deferred \(.*\); then$/\1/p' "$SUT")
[ "$loop_call" = '"$repo" $REPOS' ] \
  || bad "the loop must invoke candidate_deferred as \"\$repo\" \$REPOS (got '$loop_call') — dropping \$REPOS turns every other repo's rails into UNKNOWN load and re-creates the starvation with the predicate untouched"
guard_call=$(sed -n 's/^[[:space:]]*rail_already_running \(.*\); _rail_rc=\$?$/\1/p' "$SUT")
[ "$guard_call" = '"$repo" "$pr"' ] \
  || bad "the loop must ASK rail_already_running about THIS REPO's #pr (got 'rail_already_running $guard_call') — a guard asked about the number alone skips the wrong repo's candidate"
skip_call=$(sed -n 's/^[[:space:]]*if rail_says_skip "\(.*\)"; then$/\1/p' "$SUT")
[ "$skip_call" = '$_rail_rc' ] \
  || bad "the loop must ACT on the guard's answer via rail_says_skip (got '$skip_call') — deleting this turns 'cannot tell' back into a launch"
search_redirect=$(sed -n 's/^[[:space:]]*python3 - "\$repo" "\$RED_CAP" <<.PY. \(.*\)$/\1/p' "$SUT")
case "$search_redirect" in
  '2>> "$LOG" > "$_cand"') ;;
  *) bad "the candidate search's stderr must go to \$LOG, not to the script's inherited stderr (got '$search_redirect') — unredirected it lands in launchd's StandardErrorPath, the channel this file documents as the grave of the original defect" ;;
esac

# ══ THE BOUND STILL BITES, in both clauses ═══════════════════════════════════════════════════════════
TABLE="$(for i in 1 2 3 4 5 6 7 8; do echo "bash /r/scripts/admin-merge.sh $i --repo daniel-ospina/tortoise"; done)"
MAX_TOTAL=16 MAX=8
rails_should_defer daniel-ospina/tortoise $REPOS || bad "8 rails on ONE repo must defer a 9th candidate there"
TABLE="$(for i in $(seq 1 16); do echo "bash /r/scripts/admin-merge.sh $i --repo daniel-ospina/agent-infra"; done)"
MAX_TOTAL=16 MAX=8
rails_should_defer daniel-ospina/tortoise $REPOS || bad "the MAX_TOTAL clause must bite at 16 live"

# Fail-closed: unknown load counts for EVERY repo, never for none.
TABLE="$(for i in $(seq 1 8); do echo "bash /opt/other/scripts/admin-merge.sh $i --repo some-org/third-repo"; done)"
MAX_TOTAL=16 MAX=8
read -r u_own u_total u_unk <<< "$(rails_for_repo daniel-ospina/tortoise $REPOS)"
[ "$u_own" -eq 0 ] && [ "$u_unk" -eq 8 ] || bad "a --repo naming an undriven repo must be unknown (own=$u_own unk=$u_unk)"
rails_should_defer daniel-ospina/tortoise $REPOS || bad "8 unattributable rails must count against every repo's MAX"

# Precedence: `--repo` decides, so one rail is never counted on two repos.
TABLE="bash /Users/x/agent-infra/.worktrees/y/scripts/admin-merge.sh 42 --repo daniel-ospina/tortoise"
read -r p_t_own p_t_total _p <<< "$(rails_for_repo daniel-ospina/tortoise $REPOS)"
read -r p_a_own _p2 _p3 <<< "$(rails_for_repo daniel-ospina/agent-infra $REPOS)"
[ "$p_t_own" -eq 1 ] && [ "$p_a_own" -eq 0 ] \
  || bad "--repo must take precedence over the script path (tortoise=$p_t_own agent-infra=$p_a_own)"

# ══ THE DUPLICATE-RAIL GUARD: three answers, and per REPO ════════════════════════════════════════════
TABLE="bash /r/scripts/admin-merge.sh 3136 --repo daniel-ospina/agent-infra
bash /r/scripts/admin-merge.sh 3136 --repo daniel-ospina/agent-infra"
rail_already_running daniel-ospina/agent-infra 3136; [ $? -eq 0 ] || bad "a live rail for #3136 must be DETECTED (rc 0)"
rail_already_running daniel-ospina/agent-infra 9999; [ $? -eq 1 ] || bad "with no rail for #9999 the guard must answer rc 1 (not running), not a refusal"

# ⛔ PR NUMBERS ARE PER REPO, SO THE NUMBER ALONE IS NOT A KEY (review round 5, measured P2). A live rail
# on agent-infra#2710 used to make TORTOISE#2710 skip for that pass — one repo's rail silencing another's
# candidate, inside the guard written to prevent duplicate rails.
TABLE="bash /r/scripts/admin-merge.sh 2710 --repo daniel-ospina/agent-infra"
rail_already_running daniel-ospina/agent-infra 2710; [ $? -eq 0 ] || bad "a live rail on agent-infra#2710 must be detected for agent-infra (rc 0)"
rail_already_running daniel-ospina/tortoise 2710 && bad "a live rail on agent-infra#2710 must NOT read as a rail on tortoise#2710 — that is the repo-blind guard"
# …but a rail that cannot be attributed at all still blocks (it MIGHT be this repo's).
TABLE="bash /r/scripts/admin-merge.sh 2710"
rail_already_running daniel-ospina/tortoise 2710 || bad "an UNATTRIBUTABLE rail on #2710 must block (fail-closed) — skip on 'cannot tell', never launch"

# ⛔ THE PR NUMBER IS NOT ALWAYS FOLLOWED BY AN ARGUMENT. `admin-merge.sh <PR>` — the form this repo's
# own merge path tells operators to use — puts it LAST, and the old `grep "admin-merge.sh $1 "` needed a
# trailing space, so it answered rc 1 ("no rail") for a rail that was live.
for _shape in "bash /r/hub/scripts/admin-merge.sh 3136" \
              "bash /r/hub/scripts/admin-merge.sh 3136 --repo daniel-ospina/agent-infra" \
              "bash /r/hub/scripts/admin-merge.sh --repo daniel-ospina/agent-infra 3136"; do
  TABLE="$_shape"
  rail_already_running daniel-ospina/agent-infra 3136 || bad "this is a live rail for #3136 and the guard must DETECT it: $_shape"
done
for _shape in "bash /r/hub/scripts/admin-merge.sh 13136 --repo daniel-ospina/agent-infra" \
              "bash /r/hub/scripts/admin-merge.sh 31360 --repo daniel-ospina/agent-infra" \
              "bash /r/hub/scripts/admin-merge.sh 9999 --repo daniel-ospina/agent-infra"; do
  TABLE="$_shape"
  rail_already_running daniel-ospina/agent-infra 3136 && bad "the PR token must be boundary-matched — #3136 is NOT running here: $_shape"
done
# ⛔ AN OPTION VALUE CAN ITSELF BE A NUMBER, AND "WHICH TOKEN IS THE PR" IS NOT DECIDABLE FROM THE ROW
# (measured, review rounds 5-6). `--main-runs 10 3136` made a FIRST-number rule read the PR as `10` and miss
# the live rail for #3136 — a duplicate launch. A "first number not after a flag" rule then lost the shape
# `--main-runs 10 --any-workflow 3136`, where a BOOLEAN flag sits between the two numbers. So the row now
# carries EVERY numeric token and the guard treats ANY match as live: fail-closed, because a false skip
# costs one candidate one pass, while a missed rail costs a duplicate merge attempt and a slot.
TABLE="bash /r/hub/scripts/admin-merge.sh --main-runs 10 3136 --repo daniel-ospina/agent-infra"
rail_already_running daniel-ospina/agent-infra 3136 || bad "#3136 IS running in '--main-runs 10 3136' — an option value must not hide the PR"
rail_already_running daniel-ospina/agent-infra 10 || bad "#10 is also a numeric token of that rail, and the guard is fail-closed: it must read as possibly-running"
TABLE="bash /r/hub/scripts/admin-merge.sh --main-runs 10 --any-workflow 3136 --repo daniel-ospina/agent-infra"
rail_already_running daniel-ospina/agent-infra 3136 || bad "a BOOLEAN flag between an option value and the PR must not hide the PR: #3136 IS running here"
TABLE="bash /r/hub/scripts/admin-merge.sh --main-runs 10 --repo daniel-ospina/agent-infra"
rail_already_running daniel-ospina/agent-infra 4242 && bad "a rail whose only number is an option value must not match an unrelated PR by accident"
TABLE="bash /r/hub/scripts/admin-merge.sh 4242 --main-runs 7 --repo daniel-ospina/agent-infra"
rail_already_running daniel-ospina/agent-infra 4242 || bad "the shipped launch shape ('<PR> --repo …') must always be detected, whatever options follow"

# ⛔ AN EMPTY BOX IS `0 0 0`, NOT ONE UNKNOWN RAIL (measured, review round 6). `printf '%s\n' ""` emits one
# EMPTY line and awk counts it as a record, so every idle pass logged `rails_live=1 unattributed=1` — false
# on every idle box — and at a legal `MAX=1` the phantom rail made `own+unk >= MAX` true for ever: a
# silent total stall. This arm goes through the SHIPPED counter and predicate, not a stub of either.
TABLE=""
read -r e_own e_total e_unk <<< "$(rails_for_repo daniel-ospina/tortoise $REPOS)"
[ "$e_own/$e_total/$e_unk" = "0/0/0" ] || bad "an EMPTY process table must read 0 0 0, got $e_own/$e_total/$e_unk — a phantom unattributed rail is false on every idle pass"
TABLE="python3 /some/other/process 1
bash /r/scripts/admin-merge-helper.sh 2"
read -r e2_own e2_total e2_unk <<< "$(rails_for_repo daniel-ospina/tortoise $REPOS)"
[ "$e2_own/$e2_total/$e2_unk" = "0/0/0" ] || bad "a table with no rail in it must read 0 0 0, got $e2_own/$e2_total/$e2_unk"
TABLE=""
MAX=1 MAX_TOTAL=1
rails_should_defer daniel-ospina/tortoise $REPOS && bad "on an IDLE box with MAX=1 a candidate must LAUNCH — a phantom unattributed rail defers it for ever"
MAX=8 MAX_TOTAL=16

# The pass's ACTION, driven from the guard's contract. 0 = live, 1 = none, 2 = CANNOT TELL.
rail_says_skip 0   || bad "rc 0 (a rail is live) must SKIP the candidate"
rail_says_skip 2   || bad "rc 2 (CANNOT TELL) must SKIP the candidate, never launch"
rail_says_skip 255 || bad "an unexpected rc must SKIP the candidate, never launch"
rail_says_skip 1   && bad "rc 1 (no rail) must PROCEED — refusing here would stall the queue"

# ══ THE DENY KEY IS (repo, pr) — not the number ══════════════════════════════════════════════════════
# `case "$DENY" in *" $pr "*)` over bare numbers meant tortoise#2597 denied agent-infra#2597: a refusal
# decided by a number that names a different repository's pull request.
DENY=" daniel-ospina/agent-infra#9 "
denied daniel-ospina/agent-infra 9 || bad "an entry keyed to agent-infra#9 must DENY agent-infra#9"
denied daniel-ospina/tortoise 9 && bad "an entry keyed to agent-infra#9 must NOT deny tortoise#9 — that is the repo-blind DENY"
denied daniel-ospina/agent-infra 90 && bad "the PR must be boundary-matched (agent-infra#9 must not deny agent-infra#90)"
DENY=""

# ══ NON-POSITIVE / NON-NUMERIC BOUNDS ARE REFUSED ════════════════════════════════════════════════════
# Driven from the SHIPPED file with a private LOG (an env seam), so the assertion can read the guard's
# own `REFUSED: …` line. `rc=3` alone is NOT discriminating: the script also exits 3 for a missing rail,
# so a deleted guard would still "pass". Each reason fragment spans the clause that a command
# substitution would delete, so a truncated message fails the arm.
_sutlog=$(mktemp)
_check_refusal() {  # <env assignments> <line prefix> <reason fragment>
  local rc
  : > "$_sutlog"
  env $1 LOG="$_sutlog" bash "$SUT" >/dev/null 2>&1; rc=$?
  [ "$rc" -eq 3 ] || bad "$1 must be REFUSED (exit 3), got rc=$rc"
  grep -qF "$2" "$_sutlog" || bad "$1 must log '$2' — a bare rc=3 is also what a missing rail produces"
  grep -qF "$3" "$_sutlog" || bad "$1 must log the REASON ('$3') — a message truncated by command substitution explains nothing"
}
_check_refusal "MAX=0"              "REFUSED: MAX="        "0 would defer every candidate for ever"
_check_refusal "MAX=0 MAX_TOTAL=16" "REFUSED: MAX="        "0 would defer every candidate for ever"
_check_refusal "MAX_TOTAL=0"        "REFUSED: MAX_TOTAL="  "aggregate clause '[ total -ge 0 ]' true"
_check_refusal "MAX=8 MAX_TOTAL=0"  "REFUSED: MAX_TOTAL="  "aggregate clause '[ total -ge 0 ]' true"
# ⛔ INTERVAL AND RED_CAP GET THE SAME GUARD (round 5): `INTERVAL=abc` makes `sleep` fail instantly and
# the `while :;` loop spins at `gh` speed against the shared 5000/h bucket; `RED_CAP=abc` reached
# `int(sys.argv[2])` and killed the candidate heredoc mid-stream, silently truncating the red list.
_check_refusal "INTERVAL=abc"       "REFUSED: INTERVAL="   "spins against the shared REST bucket"
_check_refusal "INTERVAL=0"         "REFUSED: INTERVAL="   "not a POSITIVE integer"
_check_refusal "RED_CAP=abc"        "REFUSED: RED_CAP="    "silently truncates the red list"

# ⛔ THE RAIL-VERDICT DIRECTORY IS A PRECONDITION TOO — and its absence used to be invisible: a launch
# whose redirect cannot be opened returns 0 to the caller, so the log said `launching rail` for a rail
# that never started, and the cooldown then reported "already railed … only a NEW HEAD can change" over
# it. Driven from the SHIPPED file via the RAIL_DIR seam: a throwaway rail hub is still needed because
# the gh-shim check runs first, and `RAIL_SCRIPT=/bin/true` would fail THAT check instead (measured).
_thumb=$(mktemp -d)
mkdir -p "$_thumb/hub/scripts/gh-shim"
: > "$_thumb/hub/scripts/gh-shim/gh"; chmod +x "$_thumb/hub/scripts/gh-shim/gh"
: > "$_thumb/hub/scripts/admin-merge.sh"
: > "$_sutlog"
env MAX=8 LOG="$_sutlog" RAIL_SCRIPT="$_thumb/hub/scripts/admin-merge.sh" \
    RAIL_DIR=/proc/no/such/rail-dir TRIED=/proc/no/such/tried.tsv \
    bash "$SUT" >/dev/null 2>&1; _drc=$?
[ "$_drc" -eq 3 ] || bad "an uncreatable rail-verdict directory must be REFUSED (exit 3), got rc=$_drc"
grep -q "REFUSED: cannot create a writable rail-verdict directory" "$_sutlog" \
  || bad "the rail-verdict refusal must name itself in the log — a silent per-launch failure is the defect (log: $(cat "$_sutlog"))"
rm -rf "$_thumb"

# ══ THE AGGREGATE'S DERIVATION, AND THE SHIPPED DEFAULT ══════════════════════════════════════════════
# `MAX_TOTAL=16` used to appear here as a constant, so `MAX_TOTAL=${MAX_TOTAL:-$(max_total_for …)}` could
# be replaced by `MAX * 1`, `MAX * 1000` or a flat `16` with this suite still green — and the aggregate is
# the ONLY thing stopping per-repo budgets from silently multiplying the load bound.
( MAX=8; MAX_TOTAL=; eval "$(grep -m1 '^MAX_TOTAL=' "$SUT")"; [ "$MAX_TOTAL" = 16 ] ) \
  || bad "MAX_TOTAL must derive from MAX x the repos driven (2 repos x MAX=8 => 16)"
( REPOS="a/one b/two c/three"; MAX=8; MAX_TOTAL=; eval "$(grep -m1 '^MAX_TOTAL=' "$SUT")"; [ "$MAX_TOTAL" = 24 ] ) \
  || bad "a THIRD driven repo must widen the aggregate to 24 — a derivation that ignores REPOS lets per-repo budgets multiply the bound"
( REPOS="a/one"; MAX=8; MAX_TOTAL=; eval "$(grep -m1 '^MAX_TOTAL=' "$SUT")"; [ "$MAX_TOTAL" = 8 ] ) \
  || bad "ONE driven repo must give MAX_TOTAL=8, i.e. the bound scales with REPOS and is not a constant"
( MAX_TOTAL=5; eval "$(grep -m1 '^MAX_TOTAL=' "$SUT")"; [ "$MAX_TOTAL" = 5 ] ) \
  || bad "an explicit MAX_TOTAL must not be overwritten by the derivation"
# ⛔ AND THE DERIVED DEFAULT IS EXERCISED WITH NOTHING SUPPLIED (review round 5 P1): every arm used to
# hand `MAX_TOTAL` a literal, so re-introducing round 2's defect — the aggregate derived from a name
# assigned eleven lines later — left this suite at PASS/RC=0 while the script died `line N: unbound
# variable` under `set -u` before the `while` loop. Both shipped lines are evaluated with an EMPTY
# environment here, and `set -u` is on in this file, so an undefined name in either derivation aborts
# the subshell and fails the arm.
( unset MAX MAX_TOTAL; set -u; eval "$(grep -m1 '^MAX=' "$SUT")"; eval "$(grep -m1 '^MAX_TOTAL=' "$SUT")"
  [ "$MAX" = 8 ] && [ "$MAX_TOTAL" = 16 ] ) \
  || bad "the SHIPPED defaults must be MAX=8 and MAX_TOTAL=16 with nothing supplied (the body and the plist-justifying comment both say 8; \`MAX=\${MAX:-2}\` re-shipped the recorded 'DIFFERENT POLICY … MAX=2 while the plist said 8' incident as a 4x disagreement)"

# ══ A FAILED DATA SOURCE IS NOT AN EMPTY QUEUE ═══════════════════════════════════════════════════════
ps() { return 1; }
MAX_TOTAL=16 MAX=8
rail_already_running daniel-ospina/agent-infra 3136; [ $? -eq 2 ] || bad "an unreadable process table must answer rc 2 (CANNOT TELL), never rc 1 (none)"
if candidate_deferred daniel-ospina/tortoise $REPOS; then echo "fail-closed on an unreadable process table (ps rc!=0): DEFER (correct)"
else bad "a ps that could not run read as an EMPTY population and LAUNCHED"; fi

# ⛔ AN UNREADABLE COUNTER MUST DEFER (fail-closed). The stub overrides `rails_for_repo` (not `ps`)
# because an EMPTY PROCESS TABLE legitimately yields `0 0 0`; what must fail closed is a counter that
# prints nothing usable. Two shapes: no output at all, and a SHORT parse ("0 0") that leaves the THIRD
# field EMPTY — `read` gives `own=0 total=0 unk=''`, so the string is `:0:0::` and `*::` catches it.
rails_for_repo() { printf '%s' "$RAILS_OUT"; }
MAX_TOTAL=16 MAX=8
RAILS_OUT=""
if rails_should_defer daniel-ospina/tortoise $REPOS; then echo "fail-closed on an empty counter: DEFER (correct)"
else bad "an empty counter must DEFER, not launch"; fi
RAILS_OUT="0 0"
if rails_should_defer daniel-ospina/tortoise $REPOS; then echo "fail-closed on a short parse: DEFER (correct)"
else bad "a short parse ('0 0') must DEFER, not read as free load"; fi
RAILS_OUT="0 0 0"
if rails_should_defer daniel-ospina/tortoise $REPOS; then bad "a genuinely empty population must not defer"
else echo "a genuinely empty population: LAUNCH (correct)"; fi
eval "$(sed -n '/^rails_for_repo() {/,/^}$/p' "$SUT")"   # restore the SHIPPED counter for the arms below

# ══ THE COOLDOWN: WHICH ONE APPLIES ══════════════════════════════════════════════════════════════════
# Only CONFLICTED / DRAFT / DENIED are answers that need a NEW HEAD. Everything else — INCLUDING an
# attempt that left NO verdict at all — is the short retry. The old branch fell through to COOLDOWN_S
# (6 h) when the verdict file was missing, and the pass then printed "railed 6h ago on a verdict that
# only a NEW HEAD can change" about a verdict that never existed.
_cd=$(mktemp)
printf 'BLOCK: CONFLICTED\n' > "$_cd"
[ "$(cooldown_for "$_cd")" = "$COOLDOWN_S" ] || bad "a CONFLICTED verdict must take the long cooldown"
printf 'BLOCK: PR is a DRAFT\n' > "$_cd"
[ "$(cooldown_for "$_cd")" = "$COOLDOWN_S" ] || bad "a DRAFT verdict must take the long cooldown"
printf 'BLOCK: no run of the lane actually TESTED head\n' > "$_cd"
[ "$(cooldown_for "$_cd")" = "$COOLDOWN_TRANSIENT_S" ] || bad "a verdict a green re-run can change must take the SHORT cooldown"
[ "$(cooldown_for "$_cd.nonexistent")" = "$COOLDOWN_TRANSIENT_S" ] || bad "NO verdict recorded yet must take the SHORT cooldown, not 6 h — the false-premise sentence this file exists to kill"
rm -f "$_cd"

# ══ THE LEDGER ROLLBACK ══════════════════════════════════════════════════════════════════════════════
# Written first (a fast refusal must cool down), rolled back on proof that nothing started.
TRIED=$(mktemp)
printf '1\tabc\t111\n2\tdef\t222\n' > "$TRIED"
forget_tried "$(printf '1\tabc\t111')" || bad "forget_tried must succeed on a row that is present"
grep -q '^2	def	222$' "$TRIED" || bad "the OTHER row must survive a rollback"
grep -q '^1	abc	111$' "$TRIED" && bad "the rolled-back row must be GONE"
printf '1\tabc\t111\n1\tabc\t1110\n' > "$TRIED"
forget_tried "$(printf '1\tabc\t111')"
grep -q '^1	abc	1110$' "$TRIED" || bad "the rollback must be WHOLE-LINE: a longer row sharing the prefix must survive"
# ⛔ AND THE ROLLBACK MUST WORK WHEN THE ROW IS THE LEDGER'S ONLY LINE (measured, review round 6):
# `grep -v` exits 1 when it selects NOTHING, so the shipped rollback used to no-op in exactly that case
# while `launch_rail` logged "cooldown row rolled back" — a claimed effect that did not happen.
TRIED=$(mktemp); printf '1\tabc\t111\n' > "$TRIED"
forget_tried "$(printf '1\tabc\t111')" || bad "dropping the ONLY row in the ledger is a SUCCESS, not a grep-rc-1 failure"
[ -s "$TRIED" ] && bad "the only row must be gone, leaving an EMPTY ledger (got: $(cat "$TRIED"))"

# ══ THE LAUNCH IS VERIFIED ═══════════════════════════════════════════════════════════════════════════
# `nohup … &` returns 0 whether or not anything ran, and the log then said `launching rail` for a rail
# that never started — every later pass reporting "already railed … only a NEW HEAD can change" over it.
_ldir=$(mktemp -d)
TRIED=$(mktemp)
_fakerail=$(mktemp)
printf '#!/bin/bash\necho "rail started $*"\nsleep 5\n' > "$_fakerail"; chmod +x "$_fakerail"
RAIL_SCRIPT="$_fakerail" LAUNCH_VERIFY_S=1 LOG="$_sutlog"
launch_rail daniel-ospina/tortoise 5150 deadbeef "$_ldir/auto-x-5150.out" || bad "a launch whose child is alive must be recorded as started"
grep -q '^5150	deadbeef	' "$TRIED" || bad "a started launch must leave its ledger row"
# …and a launch that produced NOTHING (unopenable verdict path) must be rolled back, not remembered.
# The ledger is reset to ONE row first: a two-row ledger hid the `grep -v`-selects-nothing case
# (measured, review round 6) — the rollback only ever exercised the branch where another row survives.
TRIED=$(mktemp)
RAIL_SCRIPT="$_fakerail" LAUNCH_VERIFY_S=1
launch_rail daniel-ospina/tortoise 5151 deadbeef /proc/no/such/dir/auto-x-5151.out 2>/dev/null && bad "a launch that never started must FAIL, not be recorded as a launch"
grep -q '^5151	deadbeef	' "$TRIED" && bad "a launch that never started must be ROLLED BACK — otherwise the next pass reports it as already railed for 6 h"
[ -s "$TRIED" ] && bad "the rollback must leave an EMPTY ledger when the failed launch was its only row (got: $(cat "$TRIED"))"
rm -rf "$_ldir" "$_fakerail"

# ══ THE LOCK: HELD, RECLAIMED, AND NOT STOLEN IN THE mkdir→pid WINDOW ══════════════════════════════
# The old reclaim read `pid` and ran `ps -p` on it, so (a) inside the window between `mkdir` and the pid
# write the holder read as stale and the lock was STOLEN — the double-rail it exists to prevent — and
# (b) a RECYCLED pid read as a live holder for ever, a permanently dead actuator with a clean log.
unset -f ps   # drop the fail-closed `ps` stub the arms above installed: these arms need the REAL table
_lk=$(mktemp -d)/lock
LOCK=$_lk   # the shipped `acquire_lock` reads $LOCK; point it at this arm's throwaway path
lock_holder_is_live "$_lk.d" && bad "a lock dir that does not exist yet is not a holder"
mkdir "$_lk.d"          # the winner's mkdir, with NO pid written yet: the window
lock_holder_is_live "$_lk.d" || bad "a FRESH lock with no pid yet is INSIDE the mkdir->pid window and must read as HELD (fail-closed) — reading it as stale is how the second instance steals the first's lock"
rm -rf "$_lk.d"
acquire_lock || bad "acquire_lock must succeed on an uncontended lock"
[ "$(cat "$_lk.d/pid" 2>/dev/null)" = "$$" ] || bad "the winner must write its own pid (got '$(cat "$_lk.d/pid" 2>/dev/null)')"
rm -rf "$_lk.d"
# A recycled pid (alive, but not an auto-rail) is not a holder once the lock is OLD…
mkdir "$_lk.d"; printf '%s\n' "$$" > "$_lk.d/pid"
touch -t 200001010000 "$_lk.d"
lock_holder_is_live "$_lk.d" && bad "a RECYCLED pid must not read as a live holder — that state is a permanently dead actuator with a clean log"
acquire_lock || bad "an aged lock with a recycled pid must be RECLAIMED, not honoured for ever"
[ "$(cat "$_lk.d/pid" 2>/dev/null)" = "$$" ] || bad "a reclaimed lock must carry the new holder's pid"
# …but the same recycled pid on a FRESH lock is still treated as held (fail-closed, no steal).
touch "$_lk.d"
lock_holder_is_live "$_lk.d" || bad "a fresh lock naming a live-but-unrelated pid must be treated as HELD until it ages out"
rm -rf "$_lk.d"
# A real holder is recognised by its ARGS, not only its pid.
bash -c 'sleep 20; :' /nonexistent-hub/scripts/auto-rail.sh &   # `; :` DEFEATS bash's exec-the-last-command
# optimisation, which would otherwise replace this process with `sleep` and drop the argv this arm needs.
_holder=$!
mkdir "$_lk.d"; printf '%s\n' "$_holder" > "$_lk.d/pid"; touch -t 200001010000 "$_lk.d"
lock_holder_is_live "$_lk.d" || bad "a live process whose argv is auto-rail IS the holder, whatever the lock's age"
kill "$_holder" 2>/dev/null
rm -rf "$_lk.d"

# ══ A FAILED SEARCH IS A VERDICT, NOT AN EMPTY QUEUE ═════════════════════════════════════════════════
: > "$_sutlog"
report_search daniel-ospina/tortoise 0 && bad "rc 0 means the queue was READ — report_search must let the pass proceed"
report_search daniel-ospina/tortoise 2 || bad "a non-zero search must stop the pass"
grep -q 'CANDIDATE-PASS-FAILED' "$_sutlog" || bad "a failed search must be said in the log an operator reads the pass line in — not only on stderr"
# …and the SHIPPED search really exits non-zero when it cannot read the queue (it used to print
# SEARCH-FAILED and `sys.exit(0)`, which no caller could distinguish from a healthy empty queue).
_pydir=$(mktemp -d); _badbin=$(mktemp -d); _pysrc="$_pydir/search.py"
_pl=$(grep -n "<<'PY'" "$SUT" | head -1 | cut -d: -f1)
_pe=$(grep -n '^PY$' "$SUT" | head -1 | cut -d: -f1)
sed -n "$((_pl+1)),$((_pe-1))p" "$SUT" > "$_pysrc"
[ -s "$_pysrc" ] || bad "could not extract the shipped candidate search from $SUT"
printf '#!/bin/bash\necho "HTTP 403: rate limited" >&2\nexit 1\n' > "$_badbin/gh"; chmod +x "$_badbin/gh"
PATH="$_badbin:$PATH" python3 "$_pysrc" daniel-ospina/tortoise 2 2>"$_pydir/err"; _pyrc=$?
[ "$_pyrc" -ne 0 ] || bad "the candidate search must EXIT NON-ZERO when gh failed — exit 0 is what made a failed source log as candidates=0"
grep -q 'SEARCH-FAILED' "$_pydir/err" || bad "the failed search must say SEARCH-FAILED (got: $(cat "$_pydir/err"))"
# …and the OTHER failure branch, a `gh` that cannot be EXECUTED AT ALL (the measured 2026-10-30 death: a
# PATH missing ~/.pi/agent/shims raised FileNotFoundError, the heredoc died, and the pass logged
# candidates=0). Two branches, two exit codes: only the parse branch was pinned by the arm above.
_pybin=$(command -v python3)
_nogh=$(mktemp -d)
PATH="$_nogh:/usr/bin:/bin" "$_pybin" "$_pysrc" daniel-ospina/tortoise 2 2>"$_pydir/err3"; _pyrc3=$?
[ "$_pyrc3" -ne 0 ] || bad "a MISSING gh must also exit non-zero (got $_pyrc3) — that is the branch that left the actuator dead for days with a placid log"
grep -q 'SEARCH-FAILED' "$_pydir/err3" || bad "a missing gh must say SEARCH-FAILED (got: $(cat "$_pydir/err3"))"
rm -rf "$_nogh"
# …and the healthy path still produces candidates, so the arm above is not satisfied by "always fails".
printf '#!/bin/bash\ncat <<JSON\n[{"number": 7, "mergeable": "MERGEABLE", "isDraft": false, "body": "review recorded: r", "statusCheckRollup": [{"name": "ci", "status": "COMPLETED", "conclusion": "SUCCESS"}]}]\nJSON\n' > "$_badbin/gh"; chmod +x "$_badbin/gh"
PATH="$_badbin:$PATH" python3 "$_pysrc" daniel-ospina/tortoise 2 2>"$_pydir/err2" > "$_pydir/out2"; _pyrc2=$?
[ "$_pyrc2" -eq 0 ] || bad "a healthy search must exit 0 (got $_pyrc2: $(cat "$_pydir/err2"))"
grep -qx '7' "$_pydir/out2" || bad "a healthy search must emit the candidate PR number (got: $(cat "$_pydir/out2"))"
rm -rf "$_pydir" "$_badbin" "$_sutlog"

[ "$fail" = 0 ] && echo "PASS: per-repo accounting launches a starved repo's candidate, identifies repos by owner/name, still bounds one repo, counts unknown load against everyone, and verifies its launches"
exit "$fail"
