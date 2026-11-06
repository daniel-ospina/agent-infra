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
# …and the three knobs #3489 adds (plus COOLDOWN_TRANSIENT_S, which was unvalidated for the same reason
# and is compared in the same arithmetic: a non-numeric value makes `[ "$age" -lt "$_cool" ]` an ERROR,
# which reads as FALSE — i.e. no cooldown at all, re-railing/re-reviewing every pass).
_check_refusal "REVIEW_COOLDOWN_S=abc" "REFUSED: REVIEW_COOLDOWN_S=" "no cooldown at all"
_check_refusal "REVIEW_COOLDOWN_S=0"   "REFUSED: REVIEW_COOLDOWN_S=" "already being reviewed"
_check_refusal "REVIEW_PER_PASS=abc"   "REFUSED: REVIEW_PER_PASS="   "not a non-negative integer"
_check_refusal "COOLDOWN_TRANSIENT_S=abc" "REFUSED: COOLDOWN_TRANSIENT_S=" "is not a positive integer"
# ⛔ REVIEW_MAX_ATTEMPTS GETS THE SAME ROWS (review round 2, P1, measured): deleting BOTH of its startup
# guards left the suite GREEN, so `REVIEW_MAX_ATTEMPTS=abc` (an error in the attempt comparison, which
# reads FALSE — no bound at all) and `REVIEW_MAX_ATTEMPTS=0` (every head EXHAUSTED before its first
# dispatch, i.e. the review arm silently dead) were both unprotected, though this PR adds both guards.
_check_refusal "REVIEW_MAX_ATTEMPTS=abc" "REFUSED: REVIEW_MAX_ATTEMPTS=" "no bound at all"
_check_refusal "REVIEW_MAX_ATTEMPTS=0"   "REFUSED: REVIEW_MAX_ATTEMPTS=" "not a POSITIVE integer"
# ⛔ THE TWO GUARDS THAT HAD NO ROW AT ALL (non-vacuity, measured by mutation: deleting BOTH
# REVIEW_ATTEMPT_WINDOW_S guards, and the LAUNCH_VERIFY_S guard, left this suite GREEN).
_check_refusal "REVIEW_ATTEMPT_WINDOW_S=abc" "REFUSED: REVIEW_ATTEMPT_WINDOW_S=" "the bound permanent"
_check_refusal "REVIEW_ATTEMPT_WINDOW_S=0"   "REFUSED: REVIEW_ATTEMPT_WINDOW_S=" "not a POSITIVE integer"
_check_refusal "LAUNCH_VERIFY_S=abc"         "REFUSED: LAUNCH_VERIFY_S="         "not a non-negative integer"
# ⛔ AND DIGITS ARE NOT ENOUGH (P2, demonstrated by driving the shipped functions): `[ 0 -ge
# 99999999999999999999 ]` ERRORS ("integer expression expected") and returns 2, which every `if` reads as
# FALSE — so a too-large REVIEW_PER_PASS stopped bounding at all (one PAID reviewer per candidate per
# pass), REVIEW_COOLDOWN_S stopped delaying a second reviewer over a head already in flight, and
# REVIEW_MAX_ATTEMPTS exhausted at ZERO attempts. The startup guard bounds the LENGTH.
_check_refusal "REVIEW_PER_PASS=99999999999999999999"          "REFUSED: REVIEW_PER_PASS="          "longer than 9 digits"
_check_refusal "REVIEW_COOLDOWN_S=99999999999999999999"         "REFUSED: REVIEW_COOLDOWN_S="         "longer than 9 digits"
_check_refusal "REVIEW_MAX_ATTEMPTS=99999999999999999999"       "REFUSED: REVIEW_MAX_ATTEMPTS="       "longer than 9 digits"

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
# ⛔ THE "RECYCLED PID" IS A SPAWNED, FOREIGN PROCESS, NOT THE SUITE'S OWN `$$` (review, P2). The old
# arms borrowed `$$`, which only means "a live pid that is not an auto-rail" when the suite is invoked as
# `bash …/auto-rail.accounting.test.sh` — under `bash -c <body>` (the only way this file can be run in an
# agent shell, #1484) the caller's own argv CONTAINS the string `auto-rail.sh`, so the holder test matched
# the suite and both arms went red for a reason that has nothing to do with the code. A spawned `sleep`
# cannot be mistaken for the actuator under any invocation.
sleep 300 & _rcl=$!
mkdir "$_lk.d"; printf '%s\n' "$_rcl" > "$_lk.d/pid"
touch -t 200001010000 "$_lk.d"
lock_holder_is_live "$_lk.d" && bad "a RECYCLED pid must not read as a live holder — that state is a permanently dead actuator with a clean log"
acquire_lock || bad "an aged lock with a recycled pid must be RECLAIMED, not honoured for ever"
[ "$(cat "$_lk.d/pid" 2>/dev/null)" = "$$" ] || bad "a reclaimed lock must carry the new holder's pid"
# …but the same recycled pid on a FRESH lock is still treated as held (fail-closed, no steal).
# ⛔ AND THE LOCK MUST NAME THE *RECYCLED* PID WHEN THIS ARM RUNS (review round 2, P2, measured): after
# `acquire_lock` reclaimed the lock, the pid in it is the SUITE's own, and under `bash -c` the suite's
# argv contains `auto-rail.sh` — so the function returned 0 at the "real holder" branch and this arm
# never reached the fail-closed rule it names. (Instrumented: pid_in_lock=suite_pid, holder_args_match=1.)
# Writing the spawned pid back is what makes the assertion about the fresh-lock rule.
touch "$_lk.d"
printf '%s\n' "$_rcl" > "$_lk.d/pid"
lock_holder_is_live "$_lk.d" || bad "a fresh lock naming a live-but-unrelated pid must be treated as HELD until it ages out"
kill "$_rcl" 2>/dev/null || true
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
# ⛔ A gh-FREE PATH, NOT "a temp dir FIRST". This arm shipped `PATH="$_nogh:/usr/bin:/bin"`, which is
# a gh-free path on a Mac and NOT one on any box with a system `gh` (every Linux cell here has
# `/usr/bin/gh`) — there the arm silently exercises the HEALTHY path and then fails its own assertion,
# i.e. it never tested the branch it is named for (measured on this box, on the base commit). The
# interpreter is invoked by ABSOLUTE path, so PATH only has to be gh-free to mean what this says.
PATH="$_nogh" "$_pybin" "$_pysrc" daniel-ospina/tortoise 2 2>"$_pydir/err3"; _pyrc3=$?
[ "$_pyrc3" -ne 0 ] || bad "a MISSING gh must also exit non-zero (got $_pyrc3) — that is the branch that left the actuator dead for days with a placid log"
grep -q 'SEARCH-FAILED' "$_pydir/err3" || bad "a missing gh must say SEARCH-FAILED (got: $(cat "$_pydir/err3"))"
rm -rf "$_nogh"
# …and the healthy path still produces candidates, so the arm above is not satisfied by "always fails".
# ⛔ THE FIXTURE NOW CARRIES THE ATTESTATION, BECAUSE THE CANDIDATE LINE DOES (#3489). The line is
# `<green|red>\t<PR>\t<at-head|stale|absent|nohead>`: the KIND decides whether a review may be bought
# (a red head has to change first) and the ATTESTATION is the classification this change exists for.
# The old fixture's body ("review recorded: r") is a substring with no head and no PR number — it was
# enough for the substring filter, and it is deliberately NOT enough for the parse below.
H7=1111111111111111111111111111111111111111
_ghbody() {  # $1 = JSON array; installs it as the stub gh
  printf '#!/bin/bash\ncat <<JSON\n%s\nJSON\n' "$1" > "$_badbin/gh"; chmod +x "$_badbin/gh"
}
_ckline() {  # $1 = the PR's JSON body text; $2 = headRefOid (or '' for absent); $3 = expected line; $4 = why
  local body=$1 head=$2 want=$3 why=$4 got
  _ghbody "[{\"number\": 7, \"mergeable\": \"MERGEABLE\", \"isDraft\": false, \"headRefOid\": \"$head\", \"body\": $(printf '%s' "$body" | python3 -c 'import json,sys;print(json.dumps(sys.stdin.read()))'), \"statusCheckRollup\": [{\"name\": \"ci\", \"status\": \"COMPLETED\", \"conclusion\": \"SUCCESS\"}]}]"
  # ⛔ NO `$( _run_search )` HELPER: a command substitution is a SUBSHELL, so an rc captured inside it
  # never reaches this arm (measured — `_pyrc2: unbound variable`) and the rc-0 assertion below would be
  # reading a variable that does not exist, i.e. pinning nothing. Capture in THIS shell.
  got=$(PATH="$_badbin:$PATH" python3 "$_pysrc" daniel-ospina/tortoise 2 2>"$_pydir/err2"); _pyrc2=$?
  # The rc-0 arm, kept from the original block: it is what stops the arms below being satisfied by a
  # search that simply always fails.
  [ "$_pyrc2" -eq 0 ] || bad "a healthy search must exit 0 (got $_pyrc2: $(cat "$_pydir/err2"))"
  [ "$got" = "$(printf '%b' "$want")" ] || bad "$why (got: '$got', wanted: '$(printf '%b' "$want")')"
}
# ⛔ A HEAD THAT CANNOT LAND MUST BUY NOTHING (review round 5, P2, measured): `mergeable` was fetched by
# the search and never read, so a green-but-CONFLICTING head was dispatched a PAID review whose verdict
# nothing can use -- the rail refuses a conflicted head -- and the rebase that fixes it is a NEW head that
# buys a second one. Driven through the shipped heredoc, because that is where the filter lives.
_conf() {  # $1 = mergeable value; prints the candidate lines for one green PR with no record
  _ghbody "[{\"number\": 11, \"mergeable\": \"$1\", \"isDraft\": false, \"headRefOid\": \"$H7\", \"body\": \"none\", \"statusCheckRollup\": [{\"name\": \"ci\", \"status\": \"COMPLETED\", \"conclusion\": \"SUCCESS\"}]}]"
  PATH="$_badbin:$PATH" python3 "$_pysrc" daniel-ospina/tortoise 2 2>/dev/null
}
[ -z "$(_conf CONFLICTING)" ] \
  || bad "a CONFLICTING head must not be a candidate (got '$(_conf CONFLICTING)') -- the rail refuses a conflicted head, so the review is money spent on a revision that cannot land, and the rebase that fixes it is a new head that buys a second one"
# …but UNKNOWN MUST STILL BE REVIEWED: GitHub computes `mergeable` lazily and reports UNKNOWN on a fresh
# head, and skipping that would stall exactly the heads this loop exists to review.
[ "$(_conf UNKNOWN)" = "$(printf 'green\t11\tabsent')" ] \
  || bad "a head whose mergeability is UNKNOWN must still be a CANDIDATE (got '$(_conf UNKNOWN)') -- GitHub computes it lazily, so a filter on anything but a DEFINITE CONFLICTING stalls every fresh head"
[ "$(_conf MERGEABLE)" = "$(printf 'green\t11\tabsent')" ] \
  || bad "a MERGEABLE head with no record must still be a CANDIDATE (got '$(_conf MERGEABLE)') -- this is the #3489 shape"
# STATE 1 — ATTESTED AT HEAD: the rail path, and nothing else, is what this PR is for.
_ckline "review recorded: reviews/7.json verdict=clean @ $H7 diff=$(printf 'a%.0s' $(seq 1 64)) (daniel-ospina/tortoise)" "$H7" 'green\t7\tat-head' \
  "a clean record AT the current head must classify as at-head (the rail's own precondition)"
# ⛔ AND A **NON-CLEAN** RECORD AT THE HEAD IS A DIFFERENT ANSWER (P1, measured 2026-11-06): check (c)
# accepts ONLY clean|clean-micro|clean-low, while `record-review.sh` mints `verdict=not-clean` for every
# review that found blocking issues (#3400) — live on this repo as #3333, #3308 and #3231. Calling that
# `at-head` launched a rail the gate refuses for ever (one wasted MAX slot every COOLDOWN_TRANSIENT_S)
# AND switched the review arm off, since at-head is the only value that does. The arm below is the one the
# `_arm` table arms cannot see: they pass the attestation as a LITERAL, so nothing exercised the
# CLASSIFIER's not-clean branch and `if head in seen: return "rejected"` was dead code with the suite green.
_ckline "review recorded: reviews/7.json verdict=not-clean @ $H7 (daniel-ospina/tortoise) findings=3" "$H7" 'green\t7\trejected' \
  "a NON-CLEAN record AT the current head must classify as 'rejected', not 'at-head' — the gate can never accept a not-clean verdict, so at-head railed an unlandable revision for ever and disabled the review arm at the same time"
_ckline "review recorded: reviews/7.json verdict=not-clean @ 2222222222222222222222222222222222222222 (daniel-ospina/tortoise)" "$H7" 'green\t7\tstale' \
  "a NON-CLEAN record at an OLDER head is stale, like any other marker bound to another head (a new head gets a new review)"
# STATE 2 — STALE: a record for an OLDER head is not an attestation for the head that would merge.
_ckline "review recorded: reviews/7.json verdict=clean @ 2222222222222222222222222222222222222222 (daniel-ospina/tortoise)" "$H7" 'green\t7\tstale' \
  "a record bound to an OLDER head must classify as stale, not at-head — 'there is a marker somewhere' is the substring rule this replaces"
# STATE 3 — ABSENT: ⛔ THE #3489 DEFECT ITSELF. This PR used to be dropped by the search entirely, so it
# was not 'waiting on a lane' — it was not a candidate, and nothing would ever move it.
_ckline "no attestation in this body" "$H7" 'green\t7\tabsent' \
  "a mergeable green PR with NO record must still be a CANDIDATE (this is the PR #3486 shape: it was dropped, and sat for ever)"
# ⛔ AND THE FALSE PASS THE SUBSTRING RULE PRODUCED: a body that mere QUOTES the marker shape, or carries
# one for another PR, or names another repo, passed `"review recorded:" in body` and was never reviewed.
# ⛔ AND THIS ARM MUST BE A *WELL-FORMED* MARKER, OR IT PINS THE ANCHOR AND NOT THE PR NUMBER (review
# round 6, P2, measured). Its body used to begin `Example: review recorded: …`, so the line was refused by
# the `^` anchor BEFORE the PR-number comparison was ever consulted: replacing `if m.group(1) != str(pr)`
# with `if False:` left the suite GREEN, exit 0. A stacked PR at the same 40-hex that quoted its SIBLING's
# record on its own line would read `at-head` for a PR with no record of its own — review arm off, rail
# refused, permanent stall — and no arm would have noticed the guard being deleted. The body is therefore
# line-anchored and complete, so the ONLY thing that can refuse it is the PR-number comparison.
# (The quoting case it used to cover is pinned by the indented / mid-sentence arms below.)
_ckline "review recorded: reviews/99.json verdict=clean @ $H7 (daniel-ospina/tortoise)" "$H7" 'green\t7\tabsent' \
  "a WELL-FORMED marker for a DIFFERENT PR number must not read as this PR's attestation — this body is line-anchored and structurally complete, so the PR-number comparison is the only guard that refuses it"
# ⛔ AND AN INDENTED / MID-SENTENCE MARKER IS A QUOTATION, NOT A RECORD (review round 3, P2, measured).
# The parse was unanchored, so a body that merely quoted THIS PR's marker shape at THIS head read `at-head`
# — while check (c) is line-anchored and REJECTS it. `at-head` is the only value that disables the review
# arm, so that PR could never be reviewed AND never pass check (c): the #3489 failure (invisible, no owner,
# permanent) reproduced by its own fix. The `Example:` arm above does not cover this — it fails on the PR
# NUMBER, not on the anchoring.
_ckline "  review recorded: reviews/7.json verdict=clean @ $H7 (daniel-ospina/tortoise)" "$H7" 'green\t7\tabsent' \
  "an INDENTED marker must not read as at-head: record-review.sh emits the marker as its own line and check (c) anchors on '^', so an indented copy is a quotation (got a false at-head, which disables the review arm for ever)"
_ckline "see review recorded: reviews/7.json verdict=clean @ $H7 (daniel-ospina/tortoise) above" "$H7" 'green\t7\tabsent' \
  "a MID-SENTENCE marker must not read as at-head — the gate matches '^review recorded:', so anything the gate will not certify must not be reported as an attestation"
# ⛔ AND A LINE THAT MERELY *STARTS* WITH A MARKER IS STILL A QUOTATION: THE GATE ANCHORS AT `$` TOO
# (review round 4, P2, measured). With only the `^`, appending anything the gate's `…( sig=<64hex>)?$`
# refuses left this parse reading `at-head` while check (c) rejected the line — and `at-head` is the only
# value that disables the review arm, so the same #3489 stall comes back from the OTHER end of the line.
_ckline "review recorded: reviews/7.json verdict=clean @ $H7 (daniel-ospina/tortoise) — pasted from the review" "$H7" 'green\t7\tabsent' \
  "a marker line with PROSE appended must not read as at-head — check (c) anchors at '\$', so a line the gate rejects must not be reported as an attestation (that is the #3489 stall, from the other end of the line)"
_ckline "review recorded: reviews/7.json verdict=clean @ $H7 (daniel-ospina/tortoise) " "$H7" 'green\t7\tabsent' \
  "a trailing SPACE must not read as at-head — the gate's '\$' refuses it, and 'at-head' is the only value that disables the review arm"
# ⛔ AND THE LINE SPLITTER ITSELF IS PART OF THE SHAPE (P1, review round 6, measured). `splitlines()`
# breaks on `\r`, `\v`, `\f`, `\x1c`-`\x1e`, `\x85`, `\u2028/\u2029`, so it SPLITS a line the gate
# reads WHOLE and STRIPS the `\r` that makes the gate's `\$` fail — the parser was strictly MORE
# permissive than check (c)'s `while IFS= read -r line` (which splits on `\n` alone). `at-head` is the one
# value that disables the review arm, so the only producer of attestations went dark for such a PR for
# ever while each pass burned a MAX slot railing a head the gate refuses. Measured by driving both
# readers on one body: a CRLF-terminated marker line (the shape `gh pr create --body-file` produces from a
# CRLF file) read at-head here and REFUSE in the gate. These two arms pin the splitter: each is at-head
# under `splitlines()` and must be `absent` now.
_ckline "review recorded: reviews/7.json verdict=clean @ $H7 (daniel-ospina/tortoise)$(printf '\r')" "$H7" 'green\t7\tabsent' \
  "a CRLF-terminated marker line must NOT read as at-head — check (c) reads lines with 'IFS= read -r' (splitting on \\n alone) so the \\r stays in the line and the gate's '\$' REFUSES it; a parser using splitlines() strips the \\r and reports at-head, which disables the review arm for a PR the gate will never accept"
_ckline "review recorded: reviews/7.json verdict=clean @ $H7 (daniel-ospina/tortoise)$(printf '\v')trailing prose" "$H7" 'green\t7\tabsent' \
  "a marker line carrying PROSE after a VERTICAL TAB must not read as at-head — splitlines() treats \\v as a line break and splits the prose off, leaving a line the pattern accepts; the gate's \\n split does not, and its '\$' refuses it"
# ⛔ AND THE OTHER DIRECTION: THE REAL EMITTED SHAPES MUST STILL CLASSIFY, or every PR reads `absent` and a
# total merge stall follows. These two are the forms record-review.sh actually writes and the first cut of
# this anchoring had to keep: the SIGNED form, and the `not-clean` trailer appended AFTER `(<repo>)`.
_ckline "review recorded: reviews/7.json verdict=clean @ $H7 diff=$(printf 'a%.0s' $(seq 1 64)) (daniel-ospina/tortoise) sig=$(printf 'b%.0s' $(seq 1 64))" "$H7" 'green\t7\tat-head' \
  "the SIGNED marker record-review.sh emits must still classify as at-head (a lexer that rejects the real shape turns every attested PR into a paid review and a permanent merge stall)"
_ckline "review recorded: reviews/7.json verdict=not-clean @ $H7 (daniel-ospina/tortoise) findings=3" "$H7" 'green\t7\trejected' \
  "the not-clean trailer (' findings=N' appended AFTER '(repo)') must still be RECOGNISED as a record for THIS head — but as 'rejected', NOT 'at-head'. 'at-head' rails a revision check (c) refuses for ever (one wasted MAX slot per COOLDOWN_TRANSIENT_S) AND switches the review arm off, since at-head is the only value that does; 'absent' would buy a review of a head already reviewed. 'rejected' is the only answer that does neither"
# ⛔ AND THE FREE-FORM NOTE IS THE SHAPE A `\\S+` SILENTLY DROPS (review round 5, P2, measured). The
# recorder documents `note=1 open P2` as its OWN example — spaces and parentheses included — so a pattern
# that refuses whitespace reads a REAL marker as `absent`, which on a green head buys a PAID review of a
# head that already has a record (`review-pr.sh`'s E_ALREADY only short-circuits `verdict=clean`). Measured
# live on agent-infra#3201: `findings=9 note=3 open P1 (…)+ 6 P2 sig=…`.
_ckline "review recorded: reviews/7.json verdict=not-clean @ $H7 (daniel-ospina/tortoise) findings=9 note=3 open P1 (User=root drop-in false PASS) + 6 P2 sig=$(printf 'b%.0s' $(seq 1 64))" "$H7" 'green\t7\trejected' \
  "the recorder's FREE-FORM note ('note=1 open P2' is its own documented example, so the value CONTAINS SPACES) must still classify — a whitespace-refusing pattern reads a real marker as 'absent' and buys a paid review of a head that already carries a record"
# ⛔ THE PERMISSIVE TAIL IS BOUNDED TO `not-clean`, AND THAT BOUND IS PINNED HERE, NOT LEFT TO CHANCE (review
# round 5, verifier). A note is free-form with no delimiter, so NOTHING can accept the real note shape and
# reject prose after it — the choice is which error to take. It is taken on `not-clean` only (whose landing
# check (c) refuses on ANY shape, so nothing about whether the PR can merge turns on it), and NOT on the
# clean family, where the strict `$` is the guarantee that a quotation cannot disable the review arm. The
# arm below states that asymmetry so a later "tidy-up" that merges the two patterns reddens instead of
# silently widening the clean one.
_ckline "review recorded: reviews/7.json verdict=not-clean @ $H7 (daniel-ospina/tortoise) findings=3 note=1 open P2 — pasted from the review" "$H7" 'green\t7\trejected' \
  "a not-clean marker with prose after its FREE-FORM note is ACCEPTED on purpose — there is no delimiter between the note and anything appended (§ above), and check (c) refuses a not-clean marker on every shape, so this cannot certify a landing; a strict tail here would read the REAL note shape as 'absent' and buy a paid re-review instead"
# ⛔ AND THE CLEAN FAMILY KEEPS THE STRICT TAIL: the SAME prose on a CLEAN marker must still be refused,
# or a quotation disables the review arm for ever (the #3489 stall). This is the pair that pins the split.
_ckline "review recorded: reviews/7.json verdict=clean @ $H7 (daniel-ospina/tortoise) findings=3 note=1 open P2 — pasted from the review" "$H7" 'green\t7\tabsent' \
  "a CLEAN marker never carries a findings/note trailer (record-review.sh only appends it for not-clean), so prose on a clean marker is a QUOTATION and must not read as at-head"
_ckline "review recorded: reviews/7.json verdict=clean @ $H7 (some-other-org/tortoise)" "$H7" 'green\t7\tabsent' \
  "a marker naming another REPO must not read as this PR's attestation — the gate binds the repo too"
_ckline "review recorded: reviews/7.json verdict=clean @ $H7 (daniel-ospina/tortoise)" "" 'green\t7\tnohead' \
  "a PR whose head could not be read must not be called at-head (nothing can be at an unknown head)"
# STATE 3b — RED AND UNATTESTED: emitted (so the loop can SAY why it is not reviewed), and ordered AFTER
# an attested red so RED_CAP is never spent on a head that a review could not land.
_ghbody "[{\"number\": 8, \"mergeable\": \"MERGEABLE\", \"isDraft\": false, \"headRefOid\": \"$H7\", \"body\": \"none\", \"statusCheckRollup\": [{\"name\": \"ci\", \"status\": \"COMPLETED\", \"conclusion\": \"FAILURE\"}]}, {\"number\": 9, \"mergeable\": \"MERGEABLE\", \"isDraft\": false, \"headRefOid\": \"$H7\", \"body\": \"review recorded: reviews/9.json verdict=clean @ $H7 (daniel-ospina/tortoise)\", \"statusCheckRollup\": [{\"name\": \"ci\", \"status\": \"COMPLETED\", \"conclusion\": \"FAILURE\"}]}]"
_redout=$(PATH="$_badbin:$PATH" python3 "$_pysrc" daniel-ospina/tortoise 1 2>"$_pydir/err2")
[ "$_redout" = "$(printf 'red\t9\tat-head')" ] \
  || bad "RED_CAP=1 must be spent on the ATTESTED red (#9 \u2014 the rail can land it) and NOT on the unattested #8, which no review could help until its head changes (got: '$_redout')"
rm -rf "$_pydir" "$_badbin" "$_sutlog"

# ══ THE REVIEW STEP: THE THREE STATES, EACH NAMED FOR THE FAILURE IT PREVENTS (#3489) ═════════════
# The loop itself cannot be executed here (it is `while :` around a live gh/ps/supervisor pass — see the
# header), so this section drives the SHIPPED functions the review branch is built from, in the order the
# loop calls them, against a stubbed `gh` and a stubbed reviewer. What each arm pins is stated with it.
eval "$(sed -n '/^review_state() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^review_dispatched_at() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^review_attempts() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^review_forgive_refusal() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^review_action() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^review_should_defer() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^publish_review_state() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^run_review() {/,/^}$/p' "$SUT")"
eval "$(sed -n '/^launch_review() {/,/^}$/p' "$SUT")"
for _fn in review_state review_dispatched_at review_action review_should_defer publish_review_state run_review launch_review; do
  command -v "$_fn" >/dev/null || { echo "FATAL: $_fn not found in $SUT"; exit 2; }
done
# ⛔ `run_review` MUST BE EXPORTED IN THE SUT, and this arm is not decoration: `launch_review` runs it
# inside `nohup bash -c`, which cannot see a shell function that was not exported. Un-exported, the child
# dies with "command not found", the wrapper never writes `REVIEW-EXIT` (the wrapper IS the wrapper), and
# every dispatched review reads as `none` — i.e. the head is re-dispatched every pass, which is the paid
# thrash the state machine exists to prevent. Measured here first: without the export, these arms fail.
grep -qx 'export -f run_review' "$SUT" \
  || bad "run_review must be exported in $SUT — launch_review calls it through 'bash -c', so an unexported wrapper makes every dispatch invisible"
export -f run_review
REVIEW_COOLDOWN_S=2700
COOLDOWN_TRANSIENT_S=900
REVIEW_MAX_ATTEMPTS=3
REVIEW_ATTEMPT_WINDOW_S=21600
LAUNCH_VERIFY_S=1
# ⛔ THE STUB `gh` IS A RECORDING ONE: `api …/comments` replays what has been posted, and
# `pr comment` APPENDS to the replay — so "does a second cycle add a second marker?" is answered by the
# stub's own state, not by a hand-written expectation.
_ghdir=$(mktemp -d); mkdir -p "$_ghdir/bin"
COMMENTS="$_ghdir/comments.txt"; POSTED="$_ghdir/posted.txt"; : > "$COMMENTS"; : > "$POSTED"
export COMMENTS POSTED
cat > "$_ghdir/bin/gh" <<'GH'
#!/bin/bash
# ⛔ THE READ IS `gh api …/comments --paginate` (a single page truncates a long comment list, and the
# marker can fall off it), so the stub answers that shape and nothing else: an invocation the SUT does
# not make fails loudly (exit 2) instead of passing silently.
# ⛔ AND `--paginate` IS PART OF THE SHAPE, NOT DECORATION (review, P2): without it every later argv was
# ignored, so DELETING the flag the shipped comment calls load-bearing left this whole block GREEN — and
# without pagination the marker falls off the read page on exactly the busiest PRs and the loop posts a
# duplicate `review-in-flight` on every pass, which is the thrash these arms exist to forbid.
case "$1" in
  api)  case "$2" in
          */issues/*/comments*) case " $* " in
                                 *" --paginate "*) ;;
                                 *) echo "gh-stub: comments read without --paginate — the marker can fall off the page" >&2; exit 2;;
                               esac
                               if [ "${GH_READ_FAILS:-0}" = 1 ]; then exit 1; fi; cat "$COMMENTS" ;;
          *) exit 2 ;;
        esac ;;
  pr)   case "$2" in
          comment) shift 3; _b=""
                   while [ "$#" -gt 0 ]; do case "$1" in --body) _b=$2; shift 2;; *) shift;; esac; done
                   printf '%s\n' "$_b" >> "$COMMENTS"; printf '%s\n' "$_b" >> "$POSTED" ;;
          *) exit 2 ;;
        esac ;;
  *) exit 2 ;;
esac
GH
chmod +x "$_ghdir/bin/gh"
_oldpath=$PATH
PATH="$_ghdir/bin:$PATH"
_rdir=$(mktemp -d)
H=3333333333333333333333333333333333333333
_marker_count() { grep -cF -- "<!-- auto-rail-review:$1" "$POSTED" 2>/dev/null || true; }

# ── STATE 1 — ATTESTED AT HEAD: the rail runs, no reviewer is dispatched ──────────────────────────
# (Pinned where the decision is MADE, in the search arms above: `green 7 at-head`.) What this arm adds
# ⛔ THE END ANCHOR IS THE BRANCH'S OWN STRUCTURAL CLOSE, NOT A COMMENT (review, P3). The previous end
# anchor was `# The rail writes its verdict…` — a prose comment sitting AFTER the branch. `sed` with a
# non-matching end anchor prints to EOF, so an unrelated one-word edit to that comment silently widened
# the range until it swallowed the rail path's own `launch_rail`, and the `*launch_rail*` arm below fired
# on a change that never touched the review branch. `/^      fi$/` is the branch's own close (every inner
# `fi` is ≥ 8 spaces); the sanity arm after the extraction refuses a degenerate range outright.
_branch=$(sed -n '/if \[ "\$_att" != at-head \] && \[ "\$_rarm" = review \]; then/,/^      fi$/p' "$SUT")
[ -n "$_branch" ] || bad "could not locate the review branch in $SUT — the arms below would then pin nothing"
case "$_branch" in
  *'_out="$RAIL_DIR/auto-'*) bad "the review-branch extraction ran PAST its own close and swallowed the rail path (the end anchor stopped matching) — every arm below would then be pinning the rail path, not the review branch" ;;
esac
printf 'state 1 (attested at head): the rail path runs and the review branch can reach neither launch_rail nor a rail launch of its own\n'
case "$_branch" in
  *launch_rail*) bad "the REVIEW branch must not launch a rail: the rail refuses a PR with no head-bound record in one line and burns a MAX slot, which is exactly what this change stops. (The rail IS launched on the at-head path, further down.)" ;;
esac
case "$_branch" in
  *launch_review*) ;;
  *) bad "the review branch must DISPATCH the reviewer — without it a mergeable, unattested PR still has no owner (#3489)" ;;
esac
case "$_branch" in
  *publish_review_state*) ;;
  *) bad "the review branch must PUBLISH the state on the PR — a state only this log knows is indistinguishable from waiting on a lane" ;;
esac
# ⛔ A RED HEAD MUST NOT BUY A REVIEW — BUT IT MUST NOT BE DROPPED EITHER (review round 3, P1, measured).
# The FIRST cut pinned this as "`[ \"$_kind\" != green ]` must be followed by a `continue`" — and that arm
# pinned the DEFECT: the `continue` is what stopped a red candidate from ever reaching the rail path, so a
# red PR carrying a marker at an OLDER head (landable through check (c)'s diff-matched carry plus the
# rail's exemption engine) became unreachable by BOTH arms. Measured on daniel-ospina/agent-infra the day
# it was found: 33 candidates, 0 green, 33 red — 14 of them red-with-a-stale-marker, i.e. the arm was
# asserting the loss of every landable candidate the fleet had.
# The decision now lives in ONE DRIVEN PREDICATE, so the arm can vary the input instead of grepping for a
# string: `review_candidate_arm <kind> <att>` -> review | rail | skip. A guard is only pinned if a
# mutation of IT reddens, and a mutation of the `red:absent)` arm (widened to `red:*)`) must redden here.
eval "$(sed -n '/^review_candidate_arm() {/,/^}$/p' "$SUT")"
command -v review_candidate_arm >/dev/null || bad "review_candidate_arm is missing from $SUT — the arm that owns a candidate must be a shipped, drivable function, not an inline condition nothing can vary"
_arm() { review_candidate_arm "$1" "$2"; }
[ "$(_arm green absent)"  = review ] || bad "a GREEN candidate with no attestation must be REVIEWED — this is the #3489 defect itself (got '$(_arm green absent)')"
[ "$(_arm green stale)"   = review ] || bad "a GREEN candidate whose marker is at an older head must be REVIEWED (got '$(_arm green stale)')"
[ "$(_arm green nohead)"  = review ] || bad "a GREEN candidate whose head could not be read must be REVIEWED (got '$(_arm green nohead)')"
[ "$(_arm green at-head)" = rail ]   || bad "an ATTESTED candidate takes today's RAIL path, untouched (got '$(_arm green at-head)')"
[ "$(_arm red at-head)"   = rail ]   || bad "an ATTESTED RED candidate takes the RAIL path — the rail's exemption engine is what lands a red head whose reds are not its own (got '$(_arm red at-head)')"
[ "$(_arm red absent)"    = skip ]   || bad "a RED candidate with NO marker at any head must buy NOTHING: there is no record for check (c) to carry and no review is bought for a red head, which must not be attested clean (#3440) (got '$(_arm red absent)')"
[ "$(_arm red stale)"     = rail ]   || bad "a RED candidate carrying a marker at an OLDER head must go to the RAIL, not be dropped — check (c) accepts a stale marker whose diff= matches the live diff (#3315) and the rail's exemption engine lands it; the 'continue' that skipped this is the P1 finding (got '$(_arm red stale)')"
# ⛔ AND THE RED-ABSENT BRANCH MUST STILL `continue` (measured on the merged head: deleting that one
# word left this whole suite GREEN). The `_arm` helper evals the decision BLOCK, so it cannot see the
# fall-through — and the fall-through is the defect: with `_rarm=skip` the next gate is false, so control
# reaches the RAIL path and a red head with no marker at ANY head is handed to the rail, which is exactly
# the "a red head must not be attested clean" case (#3440) this branch exists to stop.
grep -qF 'the red arm owns this PR"' "$SUT" \
  || bad "the red-unattested log line is gone — this arm pins the continue that must follow it"
awk '/the red arm owns this PR"$/{f=1;next} f&&/^[[:space:]]*continue$/{found=1;exit} f&&NF{exit} END{exit !found}' "$SUT" \
  || bad "the red-unattested branch must CONTINUE — without it control falls through to the rail path and a red head with no marker at any head is railed ('a red head must not be attested clean', #3440); the block-extracting arms cannot see this, so it is pinned by the line after the log"
# ⛔ A NON-CLEAN RECORD AT THE HEAD IS NOT `at-head` (P1, measured 2026-11-06). check (c) accepts ONLY
# clean|clean-micro|clean-low, while `record-review.sh` mints `verdict=not-clean` for every review that
# found blocking issues (#3400) — so `at-head` on a not-clean marker launched a rail the gate refuses
# for ever, one wasted launch every COOLDOWN_TRANSIENT_S, AND switched the review arm off (at-head is
# the only value that does) at the same time. Live instances on this repo when this was written: #3333,
# #3308, #3231.
[ "$(_arm green rejected)" = skip ] || bad "a GREEN candidate whose ONLY head-bound record is verdict=not-clean must NOT be handed to the rail — check (c) can never accept a non-clean verdict, so the rail refuses in one line on every pass for ever while at-head disables the review arm too (got '$(_arm green rejected)')"
[ "$(_arm red rejected)"  = skip ] || bad "a RED candidate whose only head-bound record is verdict=not-clean must be SKIPPED, not re-reviewed and not railed (got '$(_arm red rejected)')"
# …and the loop must PUBLISH that state rather than let it read as 'nobody has looked at this': the head
# HAS been reviewed and rejected, and the remedy is a fix (a new head), which is what the message says.
grep -A2 -F 'if [ "$_att" = rejected ]; then' "$SUT" | grep -qF 'publish_review_state "$repo" "$pr" review-found-issues "$head"' \
  || bad "a NOT-CLEAN record at the head must PUBLISH 'review-found-issues' (head-bound) — otherwise a PR blocked on its own rejected review is indistinguishable from a PR nobody has looked at, which is the #3489 invisibility on the one class where at-head also disables the review arm"
_empty_arm=$(_arm "" "")
[ "$_empty_arm" = rail ] || bad "an UNCLASSIFIABLE candidate must default to the RAIL — the arm that spends nothing — never to a paid review (got '$_empty_arm')"
# ⛔ AND THE LOOP MUST CONSULT IT, RESPECTING ALL THREE ANSWERS (review round 3, P1). A driven predicate
# the loop ignores pins nothing: the arms above would stay green with the call site reverted to the
# `[ "$_kind" != green ] ... continue` that dropped every red candidate.
grep -qF '_rarm=$(review_candidate_arm "$_kind" "$_att")' "$SUT" \
  || bad "the candidate loop must CONSULT review_candidate_arm ('_rarm=\$(review_candidate_arm \"\$_kind\" \"\$_att\")') — an inline condition here is what dropped every red candidate by BOTH arms (P1)"
# ⛔ PRESENCE IS NOT POSITION (review round 4, P2, measured). The grep above is a whole-FILE presence test,
# so moving the predicate block BELOW the review branch — the natural refactor, since they are adjacent —
# left the suite GREEN: `_rarm` kept its `rail` default, the review branch was never entered, and every
# unattested candidate was handed to the rail with the producer dead. That is #3489 itself, reported PASS.
_call_ln=$(grep -nF '_rarm=$(review_candidate_arm "$_kind" "$_att")' "$SUT" | head -1 | cut -d: -f1)
_branch_ln=$(grep -nF 'if [ "$_att" != at-head ] && [ "$_rarm" = review ]; then' "$SUT" | head -1 | cut -d: -f1)
[ -n "${_call_ln:-}" ] && [ -n "${_branch_ln:-}" ] && [ "$_call_ln" -lt "$_branch_ln" ] \
  || bad "the predicate must be CONSULTED BEFORE the review branch that consumes it (predicate call at line ${_call_ln:-MISSING}, branch at ${_branch_ln:-MISSING}) — below it, '_rarm' keeps its 'rail' default, the review arm is never entered, and every unattested candidate is railed with the producer dead while this suite stays green"
printf '%s\n' "$_branch" | grep -qF '[ "$_kind" != green ]' \
  && bad "the REVIEW branch must not carry its own red-kind guard — the red decision belongs to review_candidate_arm, and a second copy inside the branch is exactly the P1 (a 'continue' that bypasses the rail path)"
# ⛔ THE SKIP ARM'S `continue` (window widened: the not-clean-record branch below added lines between
# the `if` and the outer `continue`, so a tight -A window stopped reaching it and the arm failed for a
# reason that had nothing to do with the guard).
grep -A11 -F 'if [ "$_rarm" = skip ]; then' "$SUT" | grep -qF 'continue' \
  || bad "the 'skip' arm must CONTINUE (never fall through to the rail) — a red candidate with no marker anywhere has nothing for check (c) to carry, so railing it burns a MAX slot on the one class the base's filter deliberately dropped"
# ⛔ AND NO REVIEWER MEANS NO DISPATCH: a missing reviewer must be named per candidate, not dispatched
# into. Unpinned, deleting the guard left the suite green while the loop wrote a dispatch record and
# published `review-in-flight` — a claim that something is running — on a box with no reviewer at all.
# ⛔ AND NO REVIEWER MEANS NO DISPATCH. Same gate-vs-text distinction: the expression alone is satisfied
# while the loop dispatches into a reviewer that does not exist and publishes 'review in flight' for it.
printf '%s\n' "$_branch" | grep -A2 -F '[ "$REVIEW_AVAILABLE" != 1 ]' | grep -qF 'continue' \
  || bad "the review branch must REFUSE to dispatch when no reviewer is available — the '[ \"\$REVIEW_AVAILABLE\" != 1 ]' guard must be followed by a 'continue'; without it a box with no reviewer records a dispatch, counts an attempt against the cap, and tells the PR 'review in flight'"
# ⛔ THE TWO STATES THE LOOP MUST PUBLISH FOR ITSELF, PINNED WHERE THE LOOP CALLS THEM (review, P1/P2).
# Driving `publish_review_state` directly proves the TEXT works, not that anything ever posts it —
# measured with this very harness: deleting the loop's `review-record-unbound` publish left the suite
# GREEN, so the fix for "a clean record whose body marker is gone is log-only and invisible for ever"
# could be removed without a sound. Same for EXHAUSTED, which is what stops the paid retry loop.
printf '%s\n' "$_branch" | grep -qF 'review-record-unbound' \
  || bad "the CLEAN-but-unbound arm must PUBLISH 'review-record-unbound' — logging 're-running the recorder is the remedy' while nothing performs it and nothing appears on the PR is the #3489 invisibility again, permanently, because the key never changes without a new head"
printf '%s\n' "$_branch" | grep -qF 'review-retries-exhausted' \
  || bad "the review branch must PUBLISH 'review-retries-exhausted' when the attempts are spent — otherwise a head nobody can review reads exactly like a head waiting on a lane"
# ⛔ AND BOTH MUST BE HEAD-BOUND, ON THE EXACT CALL SHAPE (review round 2, P2, measured): a bare name
# match is satisfied by dropping the head argument, which collapses the tag to a headless
# `<!-- auto-rail-review:<state> -->` — so the second head of that PR can never publish its own marker
# (it is already present) and the message renders with nothing after "at". That is the exact invisibility
# these two states exist to remove. The `review-in-flight` arm above shows the shape: the literal call.
printf '%s\n' "$_branch" | grep -qF 'publish_review_state "$repo" "$pr" review-retries-exhausted "$head"' \
  || bad "EXHAUSTED must be published HEAD-BOUND ('publish_review_state \"\$repo\" \"\$pr\" review-retries-exhausted \"\$head\"') — a headless tag means the next head in the same state can never publish, so the PR goes invisible again"
printf '%s\n' "$_branch" | grep -qF 'publish_review_state "$repo" "$pr" review-record-unbound "$head"' \
  || bad "the unbound-record remedy must be published HEAD-BOUND ('… review-record-unbound \"\$head\"') — a headless tag is invisible on the next head, which is the #3489 defect itself"
# ⛔ AND THE AVAILABILITY ITSELF MUST BE AN HONEST ANSWER (review, P2 + P2): computed BEFORE the
# rail-hub refresh, it latches the PREVIOUS clone's contents — the exact file the refresh is what
# creates — so a job that starts while the hub is behind logs "no reviewer" for its whole lifetime and
# dispatches nothing. And `-f` alone is a NAME check: a zero-byte `review-pr.sh` exits 0, the head reads
# `clean`, and `clean` is TERMINAL — a head nobody reviewed is never looked at again.
_ref_ln=$(grep -nF 'git -C "$RAIL_HUB" fetch' "$SUT" | head -1 | cut -d: -f1)
_rav_ln=$(grep -nF 'REVIEW-UNAVAILABLE' "$SUT" | head -1 | cut -d: -f1)
[ -n "$_ref_ln" ] && [ -n "$_rav_ln" ] && [ "$_rav_ln" -gt "$_ref_ln" ] \
  || bad "REVIEW_AVAILABLE must be decided AFTER the rail-hub refresh (refresh at line ${_ref_ln:-MISSING}, availability at line ${_rav_ln:-MISSING}) — the reviewer lives in the clone the refresh updates, so an earlier test answers about the PREVIOUS clone and latches a false 'UNAVAILABLE' for the process lifetime"
grep -qF '[ -s "$REVIEW_SCRIPT" ]' "$SUT" \
  || bad "the reviewer seam needs a CAPABILITY bar, not an existence check (this repo's own: -f, -x, -s, bash -n — gate-policy.sh) — a zero-byte review-pr.sh exits 0, which reads as a CLEAN review of a head nobody read, and clean is terminal"
# ⛔ AND THE `bash -n` ARM OF THAT BAR NEEDED ITS OWN PIN (non-vacuity, measured): the arm above greps
# only `[ -s … ]` and its MESSAGE claims "-f, -x, -s, bash -n", so deleting the parse check left the
# suite GREEN. It is the only arm that catches an executable, NON-EMPTY, UNPARSABLE `review-pr.sh`: with
# it gone REVIEW_AVAILABLE latches 1, every dispatch yields `bash: syntax error` → rc=2 → `retry`, the
# attempt budget is spent, and the loop publishes a 'paid dispatch(es)' claim about money never spent.
grep -qF 'bash -n "$REVIEW_SCRIPT"' "$SUT" \
  || bad "the reviewer capability bar must PARSECHECK the reviewer ('bash -n \"\$REVIEW_SCRIPT\"') — without it an executable, non-empty, unparsable review-pr.sh latches REVIEW_AVAILABLE=1, burns the attempt budget on a reviewer that cannot run, and publishes a 'paid dispatch(es)' claim about money never spent"
# …and a dispatch that really STARTED must be announced at once — but ONLY once it started. The order
# was the reverse until review round 5 (announce, then launch): announcing first means the marker claims a
# dispatch that may be rolled back, and then every later pass must choose between leaving that claim as the
# last word and re-posting one of the pair on every pass — measured at two comments per pass on a
# persistently broken reviewer path. `launch_review` returns success only after it has PROVEN the child
# started (`kill -0`/record lines), so publishing immediately after it announces a running review within
# the verification window. Pinned by line order, both directions, because position IS the fix.
# The two call shapes are named exactly, because a looser match is satisfied by the found-issues publish
# further up the branch — measured: deleting the in-flight publish entirely left a loose order assertion GREEN.
_pub_ln=$(printf '%s\n' "$_branch" | grep -nF 'publish_review_state "$repo" "$pr" review-in-flight "$head"' | head -1 | cut -d: -f1)
_lau_ln=$(printf '%s\n' "$_branch" | grep -nF 'launch_review "$repo" "$pr" "$head" "$_rout"' | head -1 | cut -d: -f1)
[ -n "$_pub_ln" ] && [ -n "$_lau_ln" ] && [ "$_pub_ln" -gt "$_lau_ln" ] \
  || bad "the in-flight marker must be published AFTER the launch is PROVEN started (launch at line ${_lau_ln:-MISSING}, in-flight publish at line ${_pub_ln:-MISSING}) — announced before it, a rolled-back dispatch has already claimed a reviewer was dispatched, and keeping the PR truthful then costs a comment on every pass"
# The review cooldown key is the HEAD, not the PR: keyed on the PR alone, a new head would inherit the
# old head's record and the loop would hold a fixable PR for REVIEW_COOLDOWN_S for no reason.
_rout_line=$(sed -n 's/^[[:space:]]*_rout="\(.*\)"$/\1/p' "$SUT")
case "$_rout_line" in
  *'$pr-$head.out') ;;
  *) bad "the review record must be keyed by the HEAD (got '$_rout_line') — that key IS the head-keyed cooldown this step reuses" ;;
esac

# ── STATE 2 — ABSENT OR STALE AT HEAD: a reviewer IS dispatched, and the marker appears ONCE ─────
printf 'state 2 (absent/stale at head): review classified from the shipped search arms above -> DISPATCH, marker once, second cycle silent\n'
_rout="$_rdir/review-acme-widget-42-$H.out"
[ "$(review_state "$_rout")" = none ] \
  || bad "a head with NO dispatch record must read 'none', not 'pending' — 'pending' makes the loop WAIT ${REVIEW_COOLDOWN_S}s on a review nobody ever dispatched (this is the PR #3486 state, and it would be indistinguishable from progress)"
review_action "$(review_state "$_rout")" 0; [ $? -eq 1 ] \
  || bad "an unattested head with no dispatch must DISPATCH NOW (rc 1) — any other answer leaves #3489 in place"
publish_review_state acme/widget 42 review-in-flight "$H" || bad "the in-flight marker must publish"
[ "$(_marker_count 'review-in-flight')" = 1 ] || bad "the in-flight marker must appear exactly ONCE (got $(_marker_count 'review-in-flight'))"
# ⛔ THE IDEMPOTENCE ARM: a second cycle in the SAME state must add nothing. Without it the loop posts
# a fresh marker every 180 s, which is how a state marker becomes noise nobody reads — and the reviewer
# it announces is dispatched once, so the duplicate would also be a false claim about a second run.
publish_review_state acme/widget 42 review-in-flight "$H"
[ "$(_marker_count 'review-in-flight')" = 1 ] \
  || bad "re-running in the same state added a SECOND marker (got $(_marker_count 'review-in-flight')) — the marker is keyed by state+head precisely so a re-run is a no-op"
# …and a DIFFERENT head is a different key: a new dispatch after a push must be visible.
publish_review_state acme/widget 42 review-in-flight 4444444444444444444444444444444444444444
[ "$(_marker_count 'review-in-flight')" = 2 ] \
  || bad "a NEW head must be able to publish its own in-flight state (got $(_marker_count 'review-in-flight')) — a state marker that outlives its head reads as a live review of code nobody is reviewing"
# ⛔ A FAILED READ MUST NOT POST. This script has no `pipefail`: a `gh` that cannot run leaves the read
# empty, which reads as "no marker" and posts a duplicate on EVERY pass — the thrash produced by the
# check that implements idempotence. Measured pattern (round 5-6 of this file): a fail-open in the guard.
GH_READ_FAILS=1 publish_review_state acme/widget 42 review-in-flight "$H" && bad "an unreadable comment list must NOT publish (a blind post is a duplicate every pass)"
[ "$(_marker_count 'review-in-flight')" = 2 ] || bad "an unreadable comment list posted anyway (got $(_marker_count 'review-in-flight'))"
unset GH_READ_FAILS

# ── THE BURST BOUND: one repo cannot empty its whole queue into paid reviewers in one pass ───────
# Measured while implementing this: agent-infra had 8 mergeable PRs with NO record and 16 with a STALE one,
# tortoise 4 and 12 — 40 mergeable PRs this step now owns. The per-repo cap in this file counts LIVE RAILS
# (reviews are not `admin-merge` processes), so it cannot bound a review burst.
REVIEW_PER_PASS=1
review_should_defer 0 && bad "with nothing dispatched this pass, the first review must DISPATCH (the bound must not stall the queue)"
review_should_defer 1 || bad "with this repo's one dispatch spent, the next review must DEFER (REVIEW_PER_PASS=1) — otherwise the first pass starts one paid reviewer per mergeable-unattested PR"
REVIEW_PER_PASS=2
review_should_defer 1 && bad "REVIEW_PER_PASS must be READ, not hardcoded to 1 (the counter is what bounds the burst)"
review_should_defer 2 || bad "at the raised cap the bound must still bite"
REVIEW_PER_PASS=1
# …and the counter must be RESET PER REPO, or the second repo of every pass gets no reviews at all.
# ⛔ PINNED BY LINE ORDER, NOT BY TEXT PRESENCE (review, P2). `^[[:space:]]*_rdispatched=0$` matches at
# ANY indent, so moving the reset one line down — inside the candidate loop — reproduced the exact
# failure the arm's message names while the arm stayed GREEN, and a per-candidate reset makes
# REVIEW_PER_PASS inert. The increment has the mirror problem: "exists somewhere" is satisfied by an
# increment ABOVE `launch_review`, which spends the repo's only slot on a dispatch that FAILED.
_while_ln=$(grep -nF 'read -r _kind pr _att; do' "$SUT" | head -1 | cut -d: -f1)
_forrepo_ln=$(grep -nF 'for repo in $REPOS; do' "$SUT" | head -1 | cut -d: -f1)
_reset_ln=$(grep -nE '^[[:space:]]*_rdispatched=0$' "$SUT" | head -1 | cut -d: -f1)
_inc_ln=$(grep -nE '^[[:space:]]*_rdispatched=\$\(\( _rdispatched \+ 1 \)\)$' "$SUT" | head -1 | cut -d: -f1)
_lau_ln=$(grep -nF 'launch_review "$repo" "$pr" "$head" "$_rout" "$_ratt"' "$SUT" | head -1 | cut -d: -f1)
# ⛔ THE RESET NEEDS BOTH BOUNDS, NOT JUST ONE (review round 2, P2, measured): `reset < candidate loop`
# is satisfied by a reset ABOVE the `for repo` loop, which makes the budget PER PASS — repo A spends it
# and repo B gets `awaiting-review` and no review — the exact failure the arm's message names. Pinning
# the upper bound alone left that edit GREEN.
[ -n "$_forrepo_ln" ] && [ -n "$_reset_ln" ] && [ "$_forrepo_ln" -lt "$_reset_ln" ] \
  || bad "the per-pass review counter must be RESET INSIDE the per-repo loop, not above it (repo loop at line ${_forrepo_ln:-MISSING}, reset at line ${_reset_ln:-MISSING}) — above it the budget is PER PASS, so the first repo spends it and every later repo is published 'awaiting-review' and never reviewed"
[ -n "$_while_ln" ] && [ -n "$_reset_ln" ] && [ "$_reset_ln" -lt "$_while_ln" ] \
  || bad "the per-pass review counter must be RESET BEFORE the candidate loop (reset at line ${_reset_ln:-MISSING}, candidate loop at line ${_while_ln:-MISSING}) — reset inside the loop is a per-CANDIDATE budget, which makes REVIEW_PER_PASS inert"
[ -n "$_inc_ln" ] && [ -n "$_lau_ln" ] && [ "$_inc_ln" -gt "$_lau_ln" ] \
  || bad "the per-pass review counter must be INCREMENTED only AFTER a successful dispatch (increment at line ${_inc_ln:-MISSING}, launch at line ${_lau_ln:-MISSING}) — incremented before it, one REVIEW-LAUNCH-FAILED consumes the repo's only slot and starves it for the whole pass"
# ⛔ AND "AFTER a successful dispatch" IS THE GUARD, NOT THE LINE ORDER (review round 3, P1, measured):
# swapping the guard for `|| true` kept the increment after the launch and left the suite GREEN, so a
# rolled-back launch still burned the repo's only slot. A bare `|| continue` is no longer enough either:
# the rollback must PUBLISH a corrective state, so the literal is the whole statement.
grep -qF 'launch_review "$repo" "$pr" "$head" "$_rout" "$_ratt" \' "$SUT" \
  || bad "the dispatch must GUARD the counter increment ('launch_review … \\') — without it a REVIEW-LAUNCH-FAILED (rolled back, nothing consumed) still increments the per-pass counter and starves every remaining candidate of that repo"
# ⛔ AND THE GUARD MUST PUBLISH A CORRECTION, NOT JUST `continue` (review round 3, measured): when an
# earlier dispatch DID start, the PR's last word is "review in flight"; a bare `|| continue` then leaves
# that claim standing with nothing running — for ever, because the record was removed and every later
# pass republishes the same tag as a no-op. The literal is pinned whole for that reason.
grep -qF '|| { publish_review_state "$repo" "$pr" review-dispatch-failed "$head"; continue; }' "$SUT" \
  || bad "the rolled-back dispatch must PUBLISH 'review-dispatch-failed' AND continue ('|| { publish_review_state … review-dispatch-failed \"\$head\"; continue; }') — a bare '|| continue' leaves the PR asserting 'review in flight' with nothing running"
# ⛔ THE IN-FLIGHT ORDER IS PINNED IN THE BRANCH ARMS ABOVE, VIA THE `_branch` EXTRACTION — not
# repeated here. Two copies of one assertion is not a second pin: the copy that stays is the scoped
# one, which names the exact call shapes inside the review branch.
# ⛔ THE WAIT LOG MUST NAME THE WINDOW THE PREDICATE USED (review round 3, P3): `_ract` is 0 for
# retry/refused on COOLDOWN_TRANSIENT_S, so a hardcoded REVIEW_COOLDOWN_S told the operator "within its
# 2700s window" about a 900 s comparison — on the file's primary instrument. The `_rwin` selection is
# log-only and cannot be driven, so it is pinned literally, on both arms.
grep -qF 'pending) _rwin=$REVIEW_COOLDOWN_S;;' "$SUT" \
  || bad "the wait log must use REVIEW_COOLDOWN_S for a pending review"
grep -qF '*)       _rwin=$COOLDOWN_TRANSIENT_S;;' "$SUT" \
  || bad "the wait log must use COOLDOWN_TRANSIENT_S for retry/refused — that is the window the predicate actually compared against, and a log that names a different one is a false report on the file's primary instrument"
printf '%s\n' "$_branch" | grep -qF 'within its ${_rwin}s window' \
  || bad "the wait log line must print \${_rwin}, not a fixed window"
publish_review_state acme/widget 42 review-in-flight "$H"
publish_review_state acme/widget 42 review-dispatch-failed "$H"
[ "$(_marker_count 'review-dispatch-failed')" = 1 ] \
  || bad "the rolled-back dispatch must be able to CORRECT itself on the PR (got $(_marker_count 'review-dispatch-failed')) — without a corrective state a failed dispatch leaves the PR asserting 'review in flight' with nothing running, for ever"
# ⛔ AND THE CORRECTION MUST NOT OUTLIVE ITS OWN RETRY (review round 4, P3, reproduced): the failure
# notice is now the NEWEST comment and says "Nothing is reviewing this PR right now" — while the retry's
# `review-in-flight` tag already exists, so a plain presence check posts NOTHING and the failure stays the
# PR's last word while a review actually runs. Re-posting in-flight restores the truth; and ONE re-post is
# enough, so the second call must add nothing (ordering, not presence — a "does a failure tag exist" test
# would re-post on every pass for the rest of the PR's life).
_b4=$(_marker_count 'review-in-flight')
publish_review_state acme/widget 42 review-in-flight "$H"
[ "$(_marker_count 'review-in-flight')" = "$(( _b4 + 1 ))" ] \
  || bad "a re-dispatch after a rolled-back one must RE-POST 'review-in-flight' (got $(_marker_count 'review-in-flight'), want $(( _b4 + 1 ))) — otherwise the failure notice stays the PR's last word while a review runs"
publish_review_state acme/widget 42 review-in-flight "$H"
[ "$(_marker_count 'review-in-flight')" = "$(( _b4 + 1 ))" ] \
  || bad "the re-post must not become a per-pass duplicate (got $(_marker_count 'review-in-flight'), want $(( _b4 + 1 ))) — ONE re-post is enough, and a second adds nothing"
# ⛔ AND A RETRY THAT ALSO ROLLS BACK MUST RE-POST THE FAILURE (review round 5, measured on the real
# functions): after a STARTED dispatch has re-posted in-flight, its last word is "a reviewer was
# dispatched" — if the next retry rolls back and its notice is suppressed by its OWN older tag, that claim
# stays last for ever while nothing runs, which is precisely the disguise this actuator exists to remove.
# Both states therefore compare POSITIONS, and because in-flight is only published for a launch proven
# STARTED, exactly one of the pair is published per real transition — the alternation that two-way
# positional repair caused on a broken path (2 comments per pass, measured) cannot occur.
_b6=$(_marker_count 'review-dispatch-failed')
publish_review_state acme/widget 42 review-dispatch-failed "$H"
[ "$(_marker_count 'review-dispatch-failed')" = "$(( _b6 + 1 ))" ] \
  || bad "a rolled-back retry after a STARTED dispatch must RE-POST 'review-dispatch-failed' (got $(_marker_count 'review-dispatch-failed'), want $(( _b6 + 1 ))) — otherwise the re-posted 'review in flight' stays the PR's last word while nothing runs"
publish_review_state acme/widget 42 review-dispatch-failed "$H"
[ "$(_marker_count 'review-dispatch-failed')" = "$(( _b6 + 1 ))" ] \
  || bad "a repeated rolled-back dispatch must NOT post a second notice (got $(_marker_count 'review-dispatch-failed'), want $(( _b6 + 1 ))) — a broken reviewer path would then post a comment on every pass, for ever"
# …and the cycle still turns: a dispatch that finally STARTS must be able to correct the notice again.
_b7=$(_marker_count 'review-in-flight')
publish_review_state acme/widget 42 review-in-flight "$H"
[ "$(_marker_count 'review-in-flight')" = "$(( _b7 + 1 ))" ] \
  || bad "a started dispatch must re-post in-flight after any newer failure notice (got $(_marker_count 'review-in-flight'), want $(( _b7 + 1 ))) — otherwise the retry that finally works leaves 'nothing is reviewing' as the PR's last word"
# ⛔ NO UNESCAPED BACKTICK MAY APPEAR IN A MARKER'S TEXT (review round 3, measured the hard way): the
# texts are double-quoted, so a bare backtick is COMMAND SUBSTITUTION — the published comment then has a
# hole where the word was, and the shell runs the word as a command (observed: "REVIEW-LAUNCH-FAILED:
# command not found" in the middle of a suite run, with the suite still GREEN because nothing asserts the
# text's CONTENT). Escaped (\`) backticks are stripped first, so only a real one remains.
# ⛔ THE ANCHOR MUST MATCH EVERY indent — the `*)` default arm sits at 4 spaces, not 6, so a 6-space
# anchor skipped precisely the one line it could not see (review round 3, verifier).
_badbt=$(awk '/text="/ { l=$0; gsub(/\\`/,"",l); if (index(l,"`")) print NR": "l }' "$SUT")
[ -z "$_badbt" ] \
  || bad "a review-state comment text contains an UNESCAPED backtick, i.e. command substitution inside a double-quoted string — the published marker will have a hole and the shell will try to run the word: $_badbt"
# ⛔ AND THE EXHAUSTED DRAIN MUST HANG OFF THE rc-3 ARM, NOT JUST APPEAR SOMEWHERE (review round 3, P2,
# measured): the publish WAS pinned by name, so changing the discriminator to an unreachable value left
# the suite green — and rc 3 then fell through to `launch_review`, i.e. a paid dispatch on a head whose
# budget is spent, which is the one thing this state exists to stop.
grep -qF 'if [ "$_ract" -eq 3 ]; then' "$SUT" \
  || bad "the EXHAUSTED publish must hang off the rc-3 arm ('if [ \"\$_ract\" -eq 3 ]; then') — pinned only by the state's name, an unreachable discriminator lets rc 3 fall through to launch_review and buy another paid review"
# ⛔ AND THE WAIT BRANCH'S `continue` IS THE ANTI-THRASH GATE, NOT DECORATION (P1 non-vacuity, measured):
# no arm covered it, so deleting it left the suite GREEN while control fell through the `-eq 3` / `-eq 2`
# tests, past `review_should_defer 0` (false) and into `launch_review` — a SECOND concurrent PAID reviewer
# on a head already being reviewed, rewriting `_rout` and resetting the dispatch epoch the cooldown is
# measured from. At a 20–30 min review and 180 s passes that is ~10 concurrent paid reviews of one head,
# each spending an attempt against a budget it was never supposed to consume.
# An anchored on the WAIT branch's OWN LOG LINE rather than on the `if`: the `case "$_rstate"` block that
# chooses `_rwin` sits between the `if` and the `continue`, so any `-A` window that reached the `continue`
# from the `if` would also reach the NEXT arm's, and a tighter one fails for the wrong reason.
printf '%s\n' "$_branch" | grep -A2 -F 'review $_rstate at $head — dispatched' | grep -qF 'continue' \
  || bad "the WAIT branch's log line must be followed by CONTINUE — without it a head whose review is ALREADY IN FLIGHT falls through to the dispatch and buys a second concurrent paid review, resetting the cooldown key it is measured by, and nothing else in this file notices"
# ⛔ AND THE ATTEMPT BUDGET MUST BE FED INTO THE DECISION, OR THE P1 PAID LOOP IS BACK (review round 2,
# P2, measured): the loop's call is the ONLY thing that makes `$att` non-zero, so dropping the third
# argument leaves the predicate's attempt term permanently 0, `return 3` unreachable, and a paid review
# re-bought on every pass — with the suite green, because `_rattn` is still computed and still logged.
grep -qF 'review_action "$_rstate" "$_rage" "$_rattn"' "$SUT" \
  || bad "the loop must pass the attempt count into review_action ('review_action \"\$_rstate\" \"\$_rage\" \"\$_rattn\"') — without it the EXHAUSTED branch is unreachable and the bounded retry is unbounded again"
# ⛔ THE REMAINING STATE PUBLISHES WERE PINNED BY *TEXT*, NEVER BY A CALL (P1/P2 non-vacuity, measured
# 2026-11-06 with a mutation harness). Driving `publish_review_state` directly proves the MESSAGE works,
# never that anything posts it. Three call sites had no arm at all:
#   * the CAP-DEFERRAL publish — deleted, the suite stayed GREEN, and that is the state a mergeable,
#     unattested PR is in whenever the box is at MAX, i.e. the COMMON case: a log line only, which is
#     #3489 itself (nothing on the PR, indistinguishable from a lane working it);
#   * the BURST-BOUND publish — deleted, GREEN; a head queued behind this repo's own REVIEW_PER_PASS
#     budget then reads as waiting on a lane;
#   * the loop's `review-found-issues` CALL — only the state's TEXT and its marker count were pinned, so
#     deleting the call left a head the reviewer REJECTED (and which the loop correctly refuses to
#     re-review) exactly as invisible as before this change.
# ⛔ AND THE LOCATOR MUST BE BOUND TO THE BLOCK, NOT TO THE WHOLE FILE (review round 8, P2, measured):
# `_capdef=$(grep -F '…' "$SUT")` was FILE-WIDE, so ANY second line carrying the same prefix satisfied
# both assertions below — the separation this split exists for held only while the prefix happened to be
# unique, which no assertion pinned. Two mutations kept the suite GREEN, exit 0: (a) revert the `rejected`
# exclusion on the real line and add a sibling line with the same prefix carrying it for a different state;
# (b) delete the real publish and add a decoy line carrying the prefix plus all three texts. That is the
# same false PASS this file already paid for once, on the arm for the guard it now exists to protect. So
# the publish is located INSIDE the `candidate_deferred` block — the only place the cap-deferral publish
# can run — and the block is required to hold exactly ONE of them.
_capblock=$(grep -A30 -F 'if candidate_deferred "$repo" $REPOS; then' "$SUT")
_capdef=$(printf '%s\n' "$_capblock" | grep -F 'publish_review_state "$repo" "$pr" awaiting-review')
[ -n "$_capdef" ] \
  || bad "the CAP-DEFERRAL block must still PUBLISH 'awaiting-review' for a deferred candidate — measured: deleting it left the suite GREEN, so the state a mergeable unattested PR is in whenever the box is at MAX existed only in the log. Located INSIDE the 'candidate_deferred' block, so a decoy line elsewhere in the file cannot satisfy this arm (a file-wide grep did, measured)"
[ "$(printf '%s\n' "$_capdef" | grep -cF 'publish_review_state')" -eq 1 ] \
  || bad "the CAP-DEFERRAL block must hold EXACTLY ONE 'awaiting-review' publish — the assertions below are 'any matching line contains this substring', so a second one inside the same block would let either requirement be satisfied by a line that is not the cap-deferral publish"
printf '%s\n' "$_capdef" | grep -qF '[ "$_kind" = green ] && [ "$_att" != at-head ]' \
  || bad "the CAP-DEFERRAL publish line must still START '[ \"\$_kind\" = green ] && [ \"\$_att\" != at-head ]' — it is the only publish that runs while the box is at MAX, i.e. the COMMON state for a mergeable unattested PR (#3489 on the most common path)"
printf '%s\n' "$_capdef" | grep -qF '[ "$_att" != rejected ]' \
  || bad "the CAP-DEFERRAL publish must EXCLUDE 'rejected' — its text promises a reviewer 'as soon as this repo has a free slot', but review_candidate_arm maps *:rejected to skip, so a not-clean head (TERMINAL — only a new head gets a review) was left carrying a promise no dispatch would keep; under cap saturation the pass never reaches the review-found-issues publish that would correct it, so the false claim stands indefinitely"
grep -A2 -F 'if review_should_defer "$_rdispatched"; then' "$SUT" | grep -qF 'publish_review_state "$repo" "$pr" awaiting-review' \
  || bad "the BURST-BOUND deferral must publish 'awaiting-review' — deleted, the suite stayed GREEN and a head queued behind this repo's REVIEW_PER_PASS budget reads as waiting on a lane"
printf '%s\n' "$_branch" | grep -A3 -F 'if [ "$_ract" -eq 2 ]; then' | grep -qF 'publish_review_state "$repo" "$pr" review-found-issues "$head"' \
  || bad "the loop must PUBLISH 'review-found-issues' from the '\$_ract -eq 2' / issues arm — the state's TEXT and its marker count are pinned, so deleting this CALL left the suite GREEN while a head the reviewer REJECTED (and which the loop will not re-review) stayed as invisible as #3489"
# ⛔ AND A REFUSAL MUST HAND THE BUDGET BACK (review round 2, P2): `refused` ignores `$att`, so without
# this reset a run of load refusals leaves the ledger saturated and the FIRST real review that then
# fails is EXHAUSTED on its first retry — the refusal spent money that was never spent.
# ⛔ THE BOUND MUST BE A RATE, NOT A LIFETIME (review round 3, P1, measured). A lifetime count made a
# TRANSIENT environment fault permanent: `review-pr.sh` exits 3 on 17 PRE-review paths (no gh, no auth,
# unreadable PR/diff/issue list, no tmp) and 9 on 2 more, none of which spend anything — so one
# rate-limit or auth window exhausted EVERY unattested head on the box, for ever, and the published
# comment asserted money had been spent. The count is now windowed: a transient fault heals by itself
# and the bound becomes a RATE (REVIEW_MAX_ATTEMPTS per window), the only form of bound that can be
# honoured without turning an outage into a permanent block.
# ⛔ THE WINDOW IS NOT A SUBSTITUTE FOR THE REFUSAL FORGIVER, and an earlier version of this round
# claimed it was. A window bounds how long damage LASTS; it does not stop a refusal CONSUMING the budget:
# three load refusals fill the window's allowance, the box quiets, and the first real review is then
# EXHAUSTED on its first paid failure. Both mechanisms are kept — the window for the rc=3/9 class no state
# can distinguish, the forgiver for the class we CAN see — and the cross-state arms below pin the
# forgiver's half.
[ "$REVIEW_ATTEMPT_WINDOW_S" -gt 0 ] || bad "REVIEW_ATTEMPT_WINDOW_S must be positive in this suite, or every arm below is vacuous"
_now=$(date +%s)
_led="$_rdir/window.attempts"
printf '%s\n%s\n' "$_now" "$_now" > "$_led"
[ "$(review_attempts "$_led")" = 2 ] \
  || bad "two dispatches INSIDE the window must count as 2 (got '$(review_attempts "$_led")') — a count that ignores its entries makes the bound inert"
printf '%s\n' "$(( _now - REVIEW_ATTEMPT_WINDOW_S - 1 ))" >> "$_led"
[ "$(review_attempts "$_led")" = 2 ] \
  || bad "a dispatch OLDER than REVIEW_ATTEMPT_WINDOW_S must stop counting (got '$(review_attempts "$_led")', want 2) — a lifetime count turns one transient failure into a permanent EXHAUSTED head, which is the #3489 symptom rebuilt as the fix"
printf '%s\n' 'not-a-timestamp' >> "$_led"
[ "$(review_attempts "$_led")" = 2 ] \
  || bad "a corrupt ledger line must not be counted as an attempt (got '$(review_attempts "$_led")')"
printf '%s\n' "$(( _now - REVIEW_ATTEMPT_WINDOW_S - 1 ))" > "$_led"
[ "$(review_attempts "$_led")" = 0 ] \
  || bad "a ledger whose entries are ALL outside the window must read 0 attempts (got '$(review_attempts "$_led")') — otherwise a head is EXHAUSTED by history alone"
rm -f "$_led"
# ⛔ AND THE CROSS-STATE PROPERTY — THE ONE THE IN-STATE ARM CANNOT SEE (review round 3, verifier):
# `refused` ignoring its own count protects only the refusal's own pass. What must ALSO hold is that a
# free dispatch does not consume the budget a LATER PAID retry reads — otherwise three load refusals on a
# busy box leave the first real review EXHAUSTED on its first failure. The forgiver drops exactly one
# line (the refusal's own) and never a paid entry before it.
_led="$_rdir/forgive.attempts"
_now=$(date +%s)
printf '%s\n%s\n%s\n' "$_now" "$_now" "$_now" > "$_led"   # paid, paid, refusal
review_forgive_refusal "$_led"
[ "$(review_attempts "$_led")" = 2 ] \
  || bad "forgiving a refusal must drop exactly ONE line (got '$(review_attempts "$_led")', want 2) — dropping more forgives PAID attempts and re-opens the paid retry loop"
# ⛔ AND IT MUST DROP THE NEWEST, NOT THE OLDEST (P2, non-vacuity — measured): the arm above asserts only
# a COUNT on a ledger whose three entries are identical, so `sed '$d'` → `sed '1d'` SWAPPED left the suite
# GREEN while the forgiver ate the OLDEST entry — a PAYED attempt. That is precisely the defect the
# function was rewritten to prevent, restored by a one-character edit nothing could see. Timestamps are
# now distinct and the surviving CONTENT is asserted, so oldest-vs-newest is observable.
_led="$_rdir/forgive.order.attempts"
# ⛔ IN-WINDOW VALUES, NOT DECORATION (review round 5, P2, measured): the first version used 1001/1002/1003
# to make oldest-vs-newest observable, but `review_attempts` WINDOWS by `REVIEW_ATTEMPT_WINDOW_S`, so those
# epochs were filtered out and every downstream arm read 0 — the cross-state arm then fed `att=0` and could
# not fail, and the empty-ledger arms were vacuous. Distinct AND recent is the only form that discriminates
# newest-from-oldest while still counting.
_now2=$(date +%s); _o1=$(( _now2 - 30 )); _o2=$(( _now2 - 20 )); _o3=$(( _now2 - 10 ))
printf '%s\n%s\n%s\n' "$_o1" "$_o2" "$_o3" > "$_led"   # paid, paid, refusal(newest)
review_forgive_refusal "$_led"
[ "$(tr '\n' ' ' < "$_led")" = "$_o1 $_o2 " ] \
  || bad "the forgiver must drop the NEWEST ledger entry (the refusal's own) and keep the earlier PAID ones — got '$(tr '\n' ' ' < "$_led")', want '$_o1 $_o2 '; dropping the oldest forgives a paid attempt and re-opens the paid retry loop"
[ "$(review_attempts "$_led")" = 2 ] \
  || bad "the two surviving entries must still COUNT (got '$(review_attempts "$_led")', want 2) — if they are outside REVIEW_ATTEMPT_WINDOW_S the arms below read 0 and test nothing"
# ⛔ AND THE ARMS MUST READ THE LEDGER THEY BUILT (review round 5, P2, measured): a stray `rm -f` before
# these assertions deleted it, so `review_attempts` returned 0 — the cross-state arm fed `att=0` instead of
# the 2 its own message names, and the two arms after it were vacuous (and redundant with the explicit
# missing-file arm at the end). A vacuous arm here is not cosmetic: it is the ONLY composition pin
# (refusal forgiven → a LATER paid retry still dispatches), so the paid-retry loop could reopen with the
# suite green.
review_action retry $(( COOLDOWN_TRANSIENT_S + 1 )) "$(review_attempts "$_led")"; [ $? -eq 1 ] \
  || bad "CROSS-STATE: after forgiving ONE refusal, a paid retry with 2 of $REVIEW_MAX_ATTEMPTS spent must still DISPATCH (got $? on att=$(review_attempts "$_led")) — the refusal consumed a budget the next paid attempt reads"
[ "$(review_attempts "$_led")" = 2 ] \
  || bad "the cross-state arm must see the 2 SURVIVING entries, not a deleted ledger (got '$(review_attempts "$_led")')"
review_forgive_refusal "$_led"; review_forgive_refusal "$_led"
[ "$(review_attempts "$_led")" = 0 ] || bad "forgiving down to empty must leave 0, not a corrupt ledger (got '$(review_attempts "$_led")')"
review_forgive_refusal "$_led"
[ "$(review_attempts "$_led")" = 0 ] || bad "forgiving an EMPTY ledger must be a no-op"
review_forgive_refusal "$_rdir/no-such.attempts" || bad "forgiving a ledger that does not exist must be a no-op, not an error"
rm -f "$_led"
grep -qF '[ "$_rstate" = refused ] && review_forgive_refusal "$_ratt"' "$SUT" \
  || bad "the loop must CALL review_forgive_refusal, GUARDED by the refused state — unguarded it drops a line on every dispatch, so the ledger never reaches the cap and the paid retry is unbounded again; guarded on any other state it forgives paid attempts"
# ⛔ AND THE COUNT MUST BE READ FROM THE HEAD-KEYED LEDGER, NOT MANUFACTURED (review round 3, P2,
# measured): the consumer was pinned but not this line, so `_rattn=0` — or pointing it at the RECORD —
# left the suite green with the attempt term permanently zero and the paid retry loop unbounded again,
# while every driven `review_action` arm still passed on a hand-fed `$att`.
grep -qF '_rattn=$(review_attempts "$_ratt")' "$SUT" \
  || bad "the loop must read the attempt count FROM THE HEAD-KEYED LEDGER — a zeroed or misdirected source leaves the count under the cap, so EXHAUSTED is unreachable in the loop and the paid retry is unbounded while the driven arms stay green"
# ⛔ AND THE LEDGER IS KEYED BY THE HEAD, like the record it bounds (review round 2, P2, measured):
# dropping the head from the ledger name turns a PER-HOST/PER-HEAD budget into a PR-LIFETIME one, so the
# first head that spends 3 attempts poisons every later head of that PR — each new head reads 3, is
# published EXHAUSTED before dispatching anything, and the review arm is dead for that PR with a clean log.
_ratt_line=$(sed -n 's/^[[:space:]]*_ratt="\(.*\)"$/\1/p' "$SUT")
case "$_ratt_line" in
  *'$pr-$head.attempts') ;;
  *) bad "the attempt ledger must be KEYED BY THE HEAD (got '${_ratt_line:-MISSING}') — keyed by PR it accumulates across heads, so a fixed head starts with a pre-spent budget and is EXHAUSTED before its first dispatch" ;;
esac
# ── STATE 3 — REVIEW IN FLIGHT: the next cycle WAITS (no second dispatch, no second marker) ──────
# ⛔ THE ANTI-THRASH ARM. This is the state a slow review is in for 5-30 minutes, i.e. 2-10 passes.
_fakerev=$(mktemp); printf '#!/bin/bash\necho "reviewing"\nsleep 30\n' > "$_fakerev"; chmod +x "$_fakerev"
REVIEW_SCRIPT="$_fakerev"
launch_review acme/widget 42 "$H" "$_rout" "$_rdir/attempts-a" || bad "the dispatch must start (record written, child alive)"
[ "$(review_attempts "$_rdir/attempts-a")" = 1 ] \
  || bad "a VERIFIED dispatch must consume exactly one attempt (got '$(review_attempts "$_rdir/attempts-a")') — an uncounted dispatch makes REVIEW_MAX_ATTEMPTS inert and the paid loop returns"
[ "$(review_state "$_rout")" = pending ] \
  || bad "a dispatch that has produced no exit line is PENDING (got '$(review_state "$_rout")') — a live review read as a failure gets a duplicate paid for next pass"
review_action pending 0; [ $? -eq 0 ] || bad "a fresh pending review must WAIT (no second dispatch)"
review_action pending $(( REVIEW_COOLDOWN_S - 1 )); [ $? -eq 0 ] || bad "one second INSIDE the cooldown must still WAIT — the boundary is the whole arm"
review_action pending $(( REVIEW_COOLDOWN_S + 1 )); [ $? -eq 1 ] || bad "a pending review past the cooldown must be RETRIED — review-pr.sh caps itself at 1800 s, so 2700 s of silence is not a slow review, it is a dead one, and waiting for ever is a stall"
# ⛔ THE WINDOWS MUST BE READ, NOT HARDCODED (review round 3, measured). The arms above and below probe
# the cooldowns only at their SHIPPED defaults (2700 / 900), so replacing `[ "$age" -lt "$REVIEW_COOLDOWN_S" ]`
# with `[ "$age" -lt 2700 ]` — the operator knob silently disarmed — left the suite GREEN (measured).
# Every other knob in this block is varied for exactly that reason; a hardcoded window is worse than a
# hardcoded cap, because the retry arm's age is ALREADY past the short window after any real review, so a
# hardcoded value re-buys a paid review on every pass while the log reads normal. Vary both, both sides.
_cooldown_saved=$REVIEW_COOLDOWN_S; _transient_saved=$COOLDOWN_TRANSIENT_S
REVIEW_COOLDOWN_S=600; COOLDOWN_TRANSIENT_S=120
review_action pending 599;  [ $? -eq 0 ] || bad "REVIEW_COOLDOWN_S must be READ, not hardcoded to its shipped default — at REVIEW_COOLDOWN_S=600 a pending review 599 s old must WAIT"
review_action pending 601;  [ $? -eq 1 ] || bad "REVIEW_COOLDOWN_S must be READ, not hardcoded — at REVIEW_COOLDOWN_S=600 a pending review 601 s old must RETRY"
review_action retry 119;    [ $? -eq 0 ] || bad "COOLDOWN_TRANSIENT_S must be READ, not hardcoded to its shipped default — at COOLDOWN_TRANSIENT_S=120 a retry 119 s old must WAIT"
review_action retry 121;    [ $? -eq 1 ] || bad "COOLDOWN_TRANSIENT_S must be READ, not hardcoded — at COOLDOWN_TRANSIENT_S=120 a retry 121 s old must RETRY"
REVIEW_COOLDOWN_S=$_cooldown_saved; COOLDOWN_TRANSIENT_S=$_transient_saved
# the second cycle publishes nothing (same state+head), and the age comes from the RECORD
# ⛔ RELATIVE, NOT ABSOLUTE (review round 4): an absolute count makes this arm fail on any earlier arm
# that publishes the same marker, i.e. on an unrelated edit rather than on the behaviour it names.
_b5=$(_marker_count 'review-in-flight')
publish_review_state acme/widget 42 review-in-flight "$H"
[ "$(_marker_count 'review-in-flight')" = "$_b5" ] || bad "the waiting cycle added a marker (got $(_marker_count 'review-in-flight'), want $_b5)"
_ep=$(review_dispatched_at "$_rout")
case "${_ep:-}" in ''|*[!0-9]*) bad "the dispatch epoch must be readable from the record (got '${_ep:-}')" ;; esac
# ⛔ mtime IS NOT THE DISPATCH TIME: a reviewer that keeps writing output keeps refreshing mtime, so an
# mtime-keyed cooldown would never age out on exactly the reviews that are slowest.
printf 'state 3 (review in flight): pending at age 0 and at %ss -> WAIT, no second dispatch, no second marker; at %ss -> RETRY\n' "$(( REVIEW_COOLDOWN_S - 1 ))" "$(( REVIEW_COOLDOWN_S + 1 ))"
touch -t 200001010000 "$_rout"
_ep2=$(review_dispatched_at "$_rout")
[ "$_ep2" = "$_ep" ] && [ "$_ep2" -gt 946684800 ] \
  || bad "the dispatch age must come from the RECORD, not the file's mtime (record=$_ep after touch=$_ep2)"
rm -f "$_fakerev"

# ── THE OUTCOME IS DURABLE: the wrapper writes the exit line UNCONDITIONALLY ────────────────────
# A background child's status is unobservable from a later pass, so `review-pr.sh`'s rc IS the outcome
# and must be recorded by the wrapper — including when the reviewer never really ran.
_rev_issues=$(mktemp); printf '#!/bin/bash\necho "P0 something"\nexit 7\n' > "$_rev_issues"; chmod +x "$_rev_issues"
_r2="$_rdir/r2.out"; run_review "$_rev_issues" 42 acme/widget "$_r2"
[ "$(review_state "$_r2")" = issues ] || bad "rc=7 (the reviewer FOUND ISSUES) must read as 'issues' (got '$(review_state "$_r2")')"
review_action issues 0; [ $? -eq 2 ] \
  || bad "a head the reviewer already REJECTED must be TERMINAL — re-dispatching it buys the SAME verdict again, for ever, at review prices (this is the paid loop the state machine exists to prevent)"
publish_review_state acme/widget 42 review-found-issues "$H"
[ "$(_marker_count 'review-found-issues')" = 1 ] || bad "the found-issues state must be published once (got $(_marker_count 'review-found-issues'))"
_rev_clean=$(mktemp); printf '#!/bin/bash\nexit 0\n' > "$_rev_clean"; chmod +x "$_rev_clean"
_r3="$_rdir/r3.out"; run_review "$_rev_clean" 42 acme/widget "$_r3"
[ "$(review_state "$_r3")" = clean ] || bad "rc=0 must read as 'clean' (got '$(review_state "$_r3")')"
# ⛔ rc=5 IS IN THE SHIPPED TABLE AND WAS THE ONE CODE WITH NO ARM (review, P2). It means "a clean record
# already exists at this head" — the good side of a lost race — and it must be CLEAN, not `issues` and
# not `retry`: folded into `issues` the loop publishes a false "the reviewer found blocking issues" and
# never re-reviews; folded into `retry` it buys a paid review every 900 s for ever. Both shipped green.
_rev_dup=$(mktemp); printf '#!/bin/bash\nexit 5\n' > "$_rev_dup"; chmod +x "$_rev_dup"
_r5b="$_rdir/r5b.out"; run_review "$_rev_dup" 42 acme/widget "$_r5b"
[ "$(review_state "$_r5b")" = clean ] || bad "rc=5 (a clean record ALREADY EXISTS at this head) must read as 'clean' (got '$(review_state "$_r5b")') — folding it into 'issues' publishes a false found-issues claim, folding it into 'retry' re-buys the review"
review_action clean 0 0; [ $? -eq 2 ] || bad "rc=5 must be TERMINAL at this head (a lost race in the good direction owes nothing)"
# ⛔ THE POST-REVIEW FAILURE CODES ARE NOT CHEAP, AND THEY MUST ALL READ 'retry' — each one is a review
# that was PAID FOR and then failed to produce a verdict (review, P1). They are enumerated rather than
# sampled: 6 (no verdict line), 8 (head/diff moved), 9 (record arm), 10 (the P0/P1/P2 scanner did not
# run), 143 (killed by a signal). A code falling through to a DIFFERENT state is a behaviour change in
# exactly the arm the attempt bound exists to make safe.
for _rc in 6 8 9 10 143; do
  _rf="$_rdir/rf-$_rc.out"
  _rv=$(mktemp); printf '#!/bin/bash\nexit %s\n' "$_rc" > "$_rv"; chmod +x "$_rv"
  run_review "$_rv" 42 acme/widget "$_rf"
  [ "$(review_state "$_rf")" = retry ] \
    || bad "rc=$_rc must read as 'retry' (got '$(review_state "$_rf")') — a post-review failure is not a verdict, and reading it as one either ships a false claim or stalls the head"
  rm -f "$_rv"
done
review_action clean 0; [ $? -eq 2 ] \
  || bad "a CLEAN review whose marker the body does not carry yet must not be re-dispatched — re-running the recorder is the remedy, and a fresh review neither helps nor is honest"
_rev_load=$(mktemp); printf '#!/bin/bash\nexit 75\n' > "$_rev_load"; chmod +x "$_rev_load"
_r4="$_rdir/r4.out"; run_review "$_rev_load" 42 acme/widget "$_r4"
# ⛔ A REFUSAL IS ITS OWN STATE, NOT `retry` (review round 2, P2, measured). rc=75 (the load gate) and
# rc=4 (no `pi`) are documented as consuming NOTHING, but they used to enter the SAME arm as the paid
# failures — and every verified launch was counted — so three load refusals marked a head that had never
# been read as EXHAUSTED, permanently, and published "the review was paid for" about money never spent.
[ "$(review_state "$_r4")" = refused ] \
  || bad "rc=75 (a load refusal: nothing was consumed) must read as 'refused' (got '$(review_state "$_r4")') — folded into 'retry' it spends the PAID attempt budget on a dispatch that cost nothing, and three refusals permanently EXHAUST a head nobody read"
rev_4=$(mktemp); printf '#!/bin/bash\nexit 4\n' > "$rev_4"; chmod +x "$rev_4"
_r4b="$_rdir/r4b.out"; run_review "$rev_4" 42 acme/widget "$_r4b"
[ "$(review_state "$_r4b")" = refused ] \
  || bad "rc=4 (pi unavailable, before any review is paid for) must read as 'refused' (got '$(review_state "$_r4b")')"
rm -f "$rev_4"
review_action refused 0 "$REVIEW_MAX_ATTEMPTS"; [ $? -eq 0 ] \
  || bad "a load refusal must WAIT out the short retry window, not re-dispatch into a still-busy box"
review_action refused $(( COOLDOWN_TRANSIENT_S + 1 )) 0; [ $? -eq 1 ] \
  || bad "a refusal past the short window must be retried (it consumed nothing, so it still owes a first review)"
# ⛔ AND THE POINT OF THE SPLIT: a refusal must NOT be exhausted even when the ledger is saturated,
# because the ledger counts PAID attempts and a refusal spent none. This is the exact input that used to
# mark an unread head EXHAUSTED for ever — and it was asserted only in this comment for one round, which
# is why the arm below is back (review round 3, P2, measured: folding `refused` into retry's logic left
# the suite GREEN).
review_action refused $(( COOLDOWN_TRANSIENT_S + 1 )) "$REVIEW_MAX_ATTEMPTS"; [ $? -eq 1 ] \
  || bad "a refusal with the dispatch budget already spent must STILL dispatch (rc 1, got $?) — otherwise a load-gate window or a missing \`pi\` blocks heads nobody ever reviewed; the refused arm must ignore the count entirely"
# …and the cap must be READ, not hardcoded (review round 2, P2, measured): every arm above fixes the
# cap at 3 and probes att ∈ {0,1,3}, so `[ "$att" -lt 3 ]` satisfied all of them. That is exactly the
# class the REVIEW_PER_PASS arms below guard against ("must be READ, not hardcoded to 1"); the same
# guard is owed to the knob this PR adds, because a hardcoded 2 silently shortens the paid budget.
REVIEW_MAX_ATTEMPTS=2
review_action retry $(( COOLDOWN_TRANSIENT_S + 1 )) 1; [ $? -eq 1 ] \
  || bad "with REVIEW_MAX_ATTEMPTS=2 and one attempt spent, a past-window retry must still DISPATCH (got $?) — a hardcoded cap ignores the knob"
review_action retry $(( COOLDOWN_TRANSIENT_S + 1 )) 2; [ $? -eq 3 ] \
  || bad "with REVIEW_MAX_ATTEMPTS=2 and two attempts spent, a retry must be EXHAUSTED (got $?) — a hardcoded cap of 3 would keep paying"
# …and the PENDING path reads it too: hardcoded there, a dead review is retried (or exhausted) on the
# wrong count, and this probe is the only thing that sees it — att=0 and att=3 answer the same either way.
review_action pending $(( REVIEW_COOLDOWN_S + 1 )) 1; [ $? -eq 1 ] \
  || bad "with REVIEW_MAX_ATTEMPTS=2 and one attempt spent, a DEAD pending review must DISPATCH (got $?) — a hardcoded cap ignores the knob on this path too"
review_action pending $(( REVIEW_COOLDOWN_S + 1 )) 2; [ $? -eq 3 ] \
  || bad "with REVIEW_MAX_ATTEMPTS=2 and two attempts spent, a DEAD pending review must be EXHAUSTED (got $?)"
REVIEW_MAX_ATTEMPTS=3
review_action retry $(( COOLDOWN_TRANSIENT_S + 1 )) 2; [ $? -eq 1 ] \
  || bad "with REVIEW_MAX_ATTEMPTS back at 3 and two spent, a retry must DISPATCH again (got $?) — the cap is restored, not sticky"
# …while the paid failures stay bounded by the same ledger.
review_action retry $(( COOLDOWN_TRANSIENT_S + 1 )) "$REVIEW_MAX_ATTEMPTS"; [ $? -eq 3 ] \
  || bad "a PAID failure (rc=6/9/10/143) with the budget spent must be EXHAUSTED (rc 3, got $?)"
# ⛔ THE ATTEMPT BOUND — THE PAID LOOP (review, P1). `retry` used to re-dispatch for ever: rc=6/9/10
# arrive AFTER the review was paid for, so their age is ALREADY past COOLDOWN_TRANSIENT_S (the review
# itself outlasts it), which means "past the window → dispatch" was true on every pass — one full paid
# review per review-duration, at one head, indefinitely, with the record truncated each time so an
# operator could not count the attempts. The ledger is what makes the fourth one impossible.
[ "$(review_attempts "$_rdir/absent.attempts")" = 0 ] \
  || bad "a head with no attempt ledger must read 0 attempts (got '$(review_attempts "$_rdir/absent.attempts")') — any other answer either blocks the first review or invents spent money"
review_action retry $(( COOLDOWN_TRANSIENT_S + 1 )) 1; [ $? -eq 1 ] \
  || bad "with one attempt spent and the cap at $REVIEW_MAX_ATTEMPTS, a past-window retry must still DISPATCH (the bound must not fire before the cap)"
review_action retry $(( COOLDOWN_TRANSIENT_S + 1 )) "$REVIEW_MAX_ATTEMPTS"; [ $? -eq 3 ] \
  || bad "a head that has spent ALL $REVIEW_MAX_ATTEMPTS must be EXHAUSTED (rc 3), not retried — this is the paid loop the bound exists to stop"
review_action pending $(( REVIEW_COOLDOWN_S + 1 )) "$REVIEW_MAX_ATTEMPTS"; [ $? -eq 3 ] \
  || bad "a DEAD pending review (past its own 1800 s cap) whose attempts are spent must be EXHAUSTED too — otherwise the bound is bypassed by a reviewer that never writes an exit line"
review_action pending $(( REVIEW_COOLDOWN_S + 1 )) 0; [ $? -eq 1 ] \
  || bad "a dead pending review with attempts left must still be retried"
# EXHAUSTED publishes itself: a head nobody can review must not read as a head waiting on a lane.
publish_review_state acme/widget 42 review-retries-exhausted "$H"
[ "$(_marker_count 'review-retries-exhausted')" = 1 ] \
  || bad "EXHAUSTED must be published on the PR exactly once (got $(_marker_count 'review-retries-exhausted'))"
publish_review_state acme/widget 42 review-retries-exhausted "$H"
[ "$(_marker_count 'review-retries-exhausted')" = 1 ] \
  || bad "re-running in the EXHAUSTED state must add nothing (got $(_marker_count 'review-retries-exhausted'))"
# ⛔ AND THE UNBOUND-RECORD STATE: a clean record at the head whose body marker is missing (expected — the
# evidence post is best-effort, agent-infra#1224) used to be LOG-ONLY: the loop said "re-running the
# recorder is the remedy" and performed nothing, for ever, because the key never changes without a new
# head. The PR stayed as invisible as #3489's `reviewDecision=empty`. It must publish instead.
publish_review_state acme/widget 42 review-record-unbound "$H"
[ "$(_marker_count 'review-record-unbound')" = 1 ] \
  || bad "a clean-but-unbound record must be PUBLISHED on the PR (got $(_marker_count 'review-record-unbound')) — the remedy lives in a comment, and this actuator never writes records"
# …and proved OUT OF BAND: drive the shipped function twice and require a SECOND head to publish its own
# marker. Without head-keying the second is suppressed by the first, which no single-head arm can see.
_H2=5555555555555555555555555555555555555555
publish_review_state acme/widget 42 review-retries-exhausted "$_H2"
publish_review_state acme/widget 42 review-record-unbound "$_H2"
[ "$(_marker_count 'review-retries-exhausted')" = 2 ] \
  || bad "a NEW head must be able to publish its own EXHAUSTED marker (got $(_marker_count 'review-retries-exhausted'), want 2) — head-keyed state is what stops a marker outliving the revision it describes"
[ "$(_marker_count 'review-record-unbound')" = 2 ] \
  || bad "a NEW head must be able to publish its own unbound-record marker (got $(_marker_count 'review-record-unbound'), want 2)"
# ⛔ A REVIEWER THAT DIES AT ONCE STILL LEAVES AN OUTCOME. `bash /nonexistent` exits 127; without the
# unconditional exit line the state would be `pending` for ever and the head would never be retried.
_r5="$_rdir/r5.out"; run_review /nonexistent/reviewer.sh 42 acme/widget "$_r5"
[ "$(review_state "$_r5")" = retry ] \
  || bad "a reviewer that never ran must leave a RETRYABLE outcome (got '$(review_state "$_r5")') — a permanent 'pending' is a head nobody will ever look at again"
# ── AND A DISPATCH THAT CANNOT EVEN RECORD ITSELF CONSUMES NOTHING (mirrors `launch_rail`) ──────
: > "$_sutlog"
launch_review acme/widget 42 "$H" /proc/no/such/dir/r6.out 2>/dev/null && bad "a dispatch that cannot write its record must not read as started"
# ⛔ AND A FAILED WRITE MUST REMOVE THE RECORD IT TRUNCATED (P2). `>` truncates the target BEFORE the write
# runs, so a write that fails on a nearly-full volume (`disk-floor.sh` exists because that happens) leaves
# a ZERO-BYTE record: no exit line (-> `pending`) and no dispatch epoch (-> `_rage=0`, the value a real
# fresh dispatch carries), so `review_action pending 0 …` answers WAIT on every pass for ever — no
# dispatch, no publication, no exhaustion — with a log line that says a review is running.
# ⛔ PINNED BY SHAPE, AND THAT IS THE HONEST CEILING: the arm above fails AT THE OPEN (the directory does
# not exist, so nothing is truncated and there is nothing to remove), and the truncate-then-fail path
# needs a volume that fills between the two, which this suite cannot simulate without `ulimit -f` killing
# the run on SIGXFSZ. So the rollback is pinned where it lives, and deleting it reddens here.
grep -qF '|| { rm -f "$out" 2>/dev/null; log_line' "$SUT" \
  || bad "a FAILED record write must roll the truncated record back ('|| { rm -f \"\$out\" …') — left behind, a zero-byte record reads as a review in flight for ever: no exit line, no dispatch epoch, so the state machine answers WAIT on every pass and nothing is ever published or exhausted"
grep -q 'REVIEW-LAUNCH-FAILED' "$_sutlog" || bad "the failed dispatch must name itself in the log (a dispatch nobody records is a review nobody knows about)"
# ⛔ AND THE **VERIFIED-LAUNCH ROLLBACK** — THE BRANCH THE ARM ABOVE DOES NOT REACH (review, P2). The
# /proc arm fails one branch EARLIER, at the record write, and prints the SAME `REVIEW-LAUNCH-FAILED`
# string, so a grep for it is satisfied while the rollback (`rm -f "$out"` + the attempt NOT counted) is
# never executed — deleting the whole verify block left this file GREEN. Here the record write succeeds
# and the child genuinely never starts (`run_review` unexported): the dispatch must be rolled back so the
# head is retried next pass rather than reported "in flight" for REVIEW_COOLDOWN_S, and it must consume
# NO attempt — three transient nohup failures must not mark a head EXHAUSTED without one review having run.
_r7="$_rdir/r7.out"; _r7led="$_rdir/r7.attempts"
: > "$_sutlog"
unset -f run_review
export -n run_review 2>/dev/null || true
launch_review acme/widget 42 "$H" "$_r7" "$_r7led" && bad "a dispatch whose child never started must not read as started (nothing was written beyond the dispatch line and no child is alive)"
[ ! -f "$_r7" ] \
  || bad "a dispatch that never started must REMOVE its record ($_r7) — kept, the head reads 'pending' and is skipped for REVIEW_COOLDOWN_S per pass while nothing is running"
[ "$(review_attempts "$_r7led")" = 0 ] \
  || bad "an UNVERIFIED dispatch must consume no attempt (got '$(review_attempts "$_r7led")') — otherwise transient nohup failures exhaust a head that was never actually reviewed"
grep -q 'REVIEW-LAUNCH-FAILED' "$_sutlog" || bad "the rolled-back dispatch must name itself in the log"
# restore the wrapper the rollback arm removed, so nothing after this point runs under it
eval "$(sed -n '/^run_review() {/,/^}$/p' "$SUT")"; export -f run_review
command -v run_review >/dev/null || bad "run_review must be restorable after the rollback arm"; echo
# ⛔ A DISPATCH WHOSE REVIEWER ALREADY *FINISHED* IS STARTED, NOT ROLLED BACK (P1 non-vacuity, measured).
# The verification is `kill -0 "$pid" || [ "$(wc -l < "$out")" -gt 1 ]`, and the SECOND clause is the only
# thing that separates "never started" from "started AND finished inside LAUNCH_VERIFY_S". Deleting it
# left this suite GREEN while the shipped function rolled a REAL, COMPLETED outcome back to `none`, threw
# its verdict away and counted no attempt — and the next pass re-bought it. Every FAST reviewer is hit:
# rc=4 (no `pi`) and rc=75 (the load gate) exit immediately, so the `refused` state became UNREACHABLE
# from the loop and a paid review that finished quickly was paid for again, unbounded, because the
# rollback path deliberately spends no attempt.
_rfast=$(mktemp); printf '#!/bin/bash\nexit 4\n' > "$_rfast"; chmod +x "$_rfast"
_r8="$_rdir/r8.out"; _r8led="$_rdir/r8.attempts"
REVIEW_SCRIPT="$_rfast"
launch_review acme/widget 42 "$H" "$_r8" "$_r8led" \
  || bad "a reviewer that STARTED and FINISHED inside ${LAUNCH_VERIFY_S}s must read as a started dispatch (rc 0) — the 'nothing beyond the dispatch line' test is what separates it from a child that never ran, and without it every fast reviewer (rc=4/75) is rolled back and re-bought on every pass"
[ -f "$_r8" ] || bad "a FINISHED dispatch must keep its record — removing it discards a real outcome and re-buys the review"
[ "$(review_state "$_r8")" = refused ] \
  || bad "the kept record must read 'refused' from its own exit line (got '$(review_state "$_r8")') — the recorded rc IS the outcome"
[ "$(review_attempts "$_r8led")" = 1 ] \
  || bad "a FINISHED dispatch must consume exactly one attempt (got '$(review_attempts "$_r8led")') — uncounted, the per-head bound is weaker than it says"
rm -f "$_rfast"

# ⛔ "STARTED" IS NOT "STILL RUNNING" (review round 5, P2, measured): `launch_review` also accepts a child
# that started AND FINISHED inside LAUNCH_VERIFY_S (`wc -l > 1` once the wrapper appends REVIEW-EXIT), and
# `review-pr.sh` exits 4/9/75 in about a second on a loaded box — so the in-flight marker must be gated on
# the RECORD still being `pending`. Published unconditionally it is a false claim that nothing ever
# corrects: the outcome state is `refused`/`retry`, and `refused` retries on time alone and publishes
# nothing, so "review in flight" would outlive the review for ever.
_rdl=$(sed -n '/\[ "\$_rstate" = refused \] && review_forgive_refusal/,/^        continue$/p' "$SUT")
printf '%s\n' "$_rdl" | grep -qF 'case "$(review_state "$_rout")" in' \
  || bad "the in-flight publish must be GATED ON THE RECORD (no 'case \"\$(review_state \"\$_rout\")\" in' in the dispatch block) — ungated, a reviewer that already refused is reported as in flight on the PR and no state ever corrects it"
printf '%s\n' "$_rdl" | grep -qF 'refused|retry) publish_review_state "$repo" "$pr" awaiting-review' \
  || bad "a dispatch that finished WITHOUT a verdict (refused/retry) must publish awaiting-review, not in-flight — otherwise the PR's newest comment claims a live review while the state machine knows there is none"
_og=$(printf '%s\n' "$_rdl" | grep -nF 'publish_review_state "$repo" "$pr" review-in-flight "$head"' | head -1 | cut -d: -f1)
_oc=$(printf '%s\n' "$_rdl" | grep -nF 'case "$(review_state "$_rout")" in' | head -1 | cut -d: -f1)
[ -n "$_og" ] && [ -n "$_oc" ] && [ "$_og" -gt "$_oc" ] \
  || bad "the in-flight publish must sit INSIDE the pending arm (in-flight at ${_og:-MISSING}, case at ${_oc:-MISSING})"

# ⛔ A DISPATCH MUST NOT EAT THE LOOP'S CANDIDATE LIST (review round 4, P2, reproduced): the loop body
# runs from `done < "$_cand"`, so a backgrounded child INHERITS the candidate file as fd 0 — and `pi -p`
# reads piped stdin and appends it to the prompt. One dispatch would then drain every remaining row of
# that repo: later candidates are silently abandoned for the pass (including attested greens whose rail
# never launched), and the reviewer is fed the other PRs' rows as extra prompt text. Driven, not grepped:
# the shipped `launch_review` runs inside a reading loop against a reviewer that CONSUMES stdin.
_stdinrev=$(mktemp); printf '#!/bin/bash\ncat >/dev/null\nexit 6\n' > "$_stdinrev"; chmod +x "$_stdinrev"
_candstub="$_rdir/cand.stdin"
printf 'green\t101\tabsent\ngreen\t102\tat-head\ngreen\t103\tabsent\n' > "$_candstub"
_seenf="$_rdir/seen.txt"
_revsave=${REVIEW_SCRIPT:-}
REVIEW_SCRIPT="$_stdinrev"
( _seen=""
  while IFS= read -r _l; do
    _seen="$_seen|$_l"
    launch_review acme/widget 101 "$H" "$_rdir/rstdin.out" >/dev/null 2>&1 || true
  done < "$_candstub"
  printf '%s' "$_seen" > "$_seenf" )
REVIEW_SCRIPT=$_revsave
[ "$(grep -o '|' "$_seenf" 2>/dev/null | wc -l | tr -d ' ')" = 3 ] \
  || bad "a dispatch whose reviewer READS STDIN must not consume the loop's candidate list — the loop saw '$(cat "$_seenf" 2>/dev/null)', want 3 rows: with an inherited fd 0 one review drains every remaining candidate of the repo (abandoned silently) and feeds their rows into the reviewer's prompt"
grep -qF '2>&1 < /dev/null &' "$SUT" \
  || bad "the review launch must DETACH stdin (`< /dev/null`) — the loop body's fd 0 is the candidate list, and a reviewer that reads it silently drops every later candidate of the repo for that pass"
grep -qF '$extra < /dev/null > "$out" 2>&1 &' "$SUT" \
  || bad "the rail launch must DETACH stdin too — same inherited fd 0, same abandoned candidates, and it is the same file's shape"
rm -f "$_stdinrev"
rm -f "$_rev_issues" "$_rev_clean" "$_rev_load"
# ⛔ THE EXIT LINE MUST START ITS OWN LINE (P2, measured). `run_review` appends `REVIEW-EXIT rc=N` to the
# same file the reviewer writes to, and `review_state` matches it `^`-anchored per line. A child whose last
# output has NO trailing newline GLUES the exit line onto it, the parse matches NOTHING, and the head reads
# `pending` — so a head the reviewer REJECTED was re-dispatched as a fresh PAID review after the cooldown
# and never published `review-found-issues`. Reachable with the shipped reviewer: `review-pr.sh` prints
# `tail -80` of a transcript on the no-parsed-findings path, and `tail` adds no newline when the file has
# none. The wrapper now frames the line itself, so the arm drives a child that prints without one.
_rnonl=$(mktemp); printf '#!/bin/bash\nprintf "%%s" "P0 something (no trailing newline)"\nexit 7\n' > "$_rnonl"; chmod +x "$_rnonl"
_r9="$_rdir/r9.out"; run_review "$_rnonl" 42 acme/widget "$_r9"
[ "$(review_state "$_r9")" = issues ] \
  || bad "a reviewer whose last output has NO trailing newline must still be read as 'issues' (got '$(review_state "$_r9")') — the exit line glues onto its output, the anchored parse finds nothing, and a REJECTED head reads 'pending': it is re-dispatched as a fresh PAID review after the cooldown and 'review-found-issues' is never published"
rm -f "$_rnonl"
# ⛔ THE DISPATCH MUST NOT INHERIT THE CANDIDATE FILE AS STDIN (P2, measured). The loop reads candidates
# with `done < "$_cand"`, so a background child inherits fd 0 pointed at that file; `pi` DRAINS PIPED
# STDIN into its prompt, so a reviewer consumed the rest of the repo's candidate list — of four candidates
# one was processed and three were eaten, while the pass line had already reported `candidates=4`.
grep -qF 'bash "$1" "$2" --repo "$3" >> "$4" 2>&1 < /dev/null' "$SUT" \
  || bad "run_review must run the reviewer with '< /dev/null' — the loop's stdin is the CANDIDATE FILE and pi drains piped stdin, so an inherited fd 0 makes the reviewer eat the remainder of this repo's candidate list (silently: the pass line already counted them)"
grep -qF '"$out" >> "$LOG" 2>&1 < /dev/null &' "$SUT" \
  || bad "the nohup dispatch must redirect stdin from /dev/null too — otherwise the background wrapper inherits the candidate file even if run_review's own redirection were dropped"
PATH=$_oldpath
rm -rf "$_ghdir" "$_rdir"

[ "$fail" = 0 ] && echo "PASS: per-repo accounting launches a starved repo's candidate, identifies repos by owner/name, still bounds one repo, counts unknown load against everyone, and verifies its launches"
exit "$fail"
