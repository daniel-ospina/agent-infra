#!/usr/bin/env bash
# product-floor.test.sh — the regression contract for agent-infra#2054.
#
# THE DEFECT. Measured 2026-10-18 while 200 issues were open: the MIX was fine (6 of 8 in-flight
# dispatch chains product, 0% harness in the dispatch lanes) but the THROUGHPUT was not — 19 of 20
# lane slots idle and `[dispatch] backlog empty queue=READ(200)`. The queue was empty because of the
# pre-flight starvation (#2042), not because there was no product work. What the floor has to
# guarantee is that the MIX cannot silently stop being true: harness work has a dispatch path that
# BYPASSES prioritisation entirely (`nonblocking-dispatch.sh` — no pool, no pre-flight, no tier, no
# lane accounting) and carried 6 workers the same day the product channel carried zero.
#
# WHAT IS ASSERTED — the four contracts the issue names as failure modes not to create:
#   1. NO MERGE STARVATION. The floor sits AFTER `mp_reason` and inside the `[ -z "$GATE_WHY" ]`
#      branch, so a merge backlog wins outright; and an unmet floor never stops a dispatch (it is a
#      LOG LINE after the loop, not a guard). Proved three ways: `mp_reason` driven directly, the
#      whole shipped dispatch block driven with merge-priority engaged, and the dispatch call driven
#      with the floor unmet.
#   2. NO ELIGIBILITY BYPASS. The reserved slot goes through the SAME pre-flight verdict and the SAME
#      `claim_issue_acquire` — there is no second admission path. A product candidate a peer holds is
#      SKIPPED (never force-dispatched, #1850), and the floor then goes to the next product candidate
#      ("the highest-priority DISPATCHABLE product issue"), not to a force.
#   3. NO MASKED BLINDNESS. An unmet floor logs `[dispatch] product-floor unmet (…) queue=<state>`
#      carrying `queue_state_token`, so `READ(203)` with an empty product queue reads as a FAILING
#      INTAKE, never as "no product work". An ABSENT queue and an EMPTY one are named differently.
#   4. NO RE-OFFER OF CLAIMED WORK. The `dispatched.txt` check stays FIRST in the loop, ahead of the
#      floor's own bookkeeping.
#
# HOW THESE CHECKS ARE WRITTEN. The shipped blocks are EXTRACTED VERBATIM and driven — the batch
# builder from `orch-loop.sh` (`# BEGIN/END product-floor`), the classifier and the class-queue
# partition from `refresh-candidates.sh` (`# BEGIN/END product-partition`, `candidate_class()`), and
# the claims come from the SHIPPED `claims.sh` against a real throwaway bare origin, so contract 2 is
# measured on the same CAS the fleet uses. NON-VACUITY: every extraction is guarded by `need`; an
# empty extraction FAILS every dependent check rather than passing on an empty file.
#
# Run:  bash scripts/orchestrator-harness/product-floor.test.sh
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$HERE/orch-loop.sh"
REFRESH="$HERE/refresh-candidates.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/product-floor.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> product-work floor contract ($HERE)"

need() { if [ -s "$1" ]; then return 0; else bad "could not extract $2"; return 1; fi; }
for f in "$LOOP" "$REFRESH"; do [ -f "$f" ] || { echo "  ❌ missing $f"; exit 1; }; done

# ── extractions ────────────────────────────────────────────────────────────────
awk '/^  # BEGIN product-floor/,/^  # END product-floor/' "$LOOP" > "$T/floor.sh"
awk '/^# BEGIN product-partition/,/^# END product-partition/' "$REFRESH" > "$T/partition.sh"
{ grep -m1 '^is_num() {' "$LOOP"
  sed -n '/^queue_state_token() {/,/^}$/p' "$LOOP"
  sed -n '/^mp_reason() {/,/^}$/p' "$LOOP"
} > "$T/deps.sh"
sed -n '/^repo_slug_valid() {/,/^}$/p' "$REFRESH" > "$T/classify.sh"
sed -n '/^candidate_class() {/,/^}$/p' "$REFRESH" >> "$T/classify.sh"
grep -m1 '^PRODUCT_DEFAULT_REPOS=' "$REFRESH" >> "$T/classify.sh"

if need "$T/floor.sh" "the batch builder (# BEGIN/END product-floor) from orch-loop.sh"; then
  ok "orch-loop: the product-floor batch builder is extractable from the shipped loop"
  grep -q 'claim_issue_acquire' "$T/floor.sh" && grep -q 'PRODUCT_FLOOR' "$T/floor.sh" \
    && ok "orch-loop: the block still carries the cross-box claim and the floor" \
    || bad "orch-loop: the block lost the claim path or the floor"
else
  bad "orch-loop: no product-floor block — every contract below cannot be driven"
fi
if need "$T/deps.sh" "queue_state_token/mp_reason/is_num from orch-loop.sh"; then
  grep -q '^queue_state_token() {' "$T/deps.sh" && grep -q '^mp_reason() {' "$T/deps.sh" \
    && ok "orch-loop: the queue-state token and the merge-priority gate are extractable" \
    || bad "orch-loop: a dependency was not extracted"
else
  bad "orch-loop: dependencies missing"
fi

# ── the sandbox: a real bare origin + the shipped claims.sh ────────────────────
# mk_case <name> -> echoes the dir; the case then seeds candidates and drives.
mk_case() {
  local d="$T/$1"
  mkdir -p "$d/o/state" "$d/repo"
  git init -q --bare "$d/origin.git"
  git init -q "$d/repo"
  git -C "$d/repo" remote add origin "$d/origin.git"
  cp "$HERE/claims.sh" "$d/o/claims.sh"
  : > "$d/o/dispatched.txt"
  : > "$d/log"
  # A queue state with an AGE, as the shipped refresh writes it — the token must travel WITH it.
  printf 'READ(203) %s\n' "$(date +%s)" > "$d/o/state/queue-state"
  # The dispatch call is recorded rather than run: an unmet floor must not STOP it, and a
  # merge-priority drain must prevent it.
  cat > "$d/o/dispatch-merge.sh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" > "$(dirname "$0")/dispatch-invoked"
SH
  printf '%s\n' "$d"
}
# seed a PEER's live claim on issue $2 (same helper shape as refresh-scout.test.sh: the shipped
# `_claim_commit` builds the claim commit and it is pushed to refs/claims/issue-<N>).
seed_peer_claim() {
  local d="$1" n="$2" c
  c="$( cd "$d/repo" || exit 1
        CLAIM_REPO="$d/repo"; CLAIM_OWNER_ID=peerbox; export CLAIM_REPO CLAIM_OWNER_ID
        . "$HERE/claims.sh"
        _claim_commit peerbox "$(( $(date +%s) + 600 ))" )"
  [ -n "$c" ] || return 1
  git -C "$d/repo" push -q origin "$c:refs/claims/issue-$n"
}
# drive <dir> <PRODUCT_FLOOR> <GATE_WHY> [BATCH]
# Runs the SHIPPED block, in a subshell, with the shipped claims.sh sourced exactly as the daemon
# sources it ($O/claims.sh after CLAIM_REPO is set).
drive() {
  local d="$1" pf="$2" why="$3" b="${4:-2}"
  ( O="$d/o" LOG="$d/log" BATCH="$b" PRODUCT_FLOOR="$pf" GATE_WHY="$why" \
    L=0 LANES=0 WORKERS=0 REPO="$d/repo" OR="acme/widget" \
    bash -c 'CLAIM_REPO="$REPO"; . "$O/claims.sh"; . "$1"; . "$2"' _ "$T/deps.sh" "$T/floor.sh" ) \
    >> "$d/drive.out" 2>&1
}
batch()  { tr '\n' ' ' < "$1/o/.batch" 2>/dev/null | sed 's/ *$//'; }
cands()  { printf '%s\n' "$2" > "$1/o/candidates.txt"; }
prods()  { printf '%s\n' "$2" > "$1/o/candidates.product.txt"; }
probe()  { tr '\n' ' ' < "$1/o/dispatched.txt" 2>/dev/null | sed 's/ *$//'; }

if ! need "$T/floor.sh" "the batch builder"; then
  echo; echo "  PASS=$PASS FAIL=$FAIL"; exit 1
fi

# ══ (a) A BATCH OF 2 WITH A PRODUCT AND A HARNESS CANDIDATE CONTAINS THE PRODUCT ONE ═══════════
# This is indicator (a). The merged FIFO puts the HARNESS issue first (7), so today's loop would
# dispatch 7 and then 42 — the floor's whole job is that 42 cannot be displaced out of a BATCH=2.
echo; echo "── (a) the reserved slot is real: product + harness in one batch ──"
DA="$(mk_case a)"
cands "$DA" '7
42'
prods "$DA" '42'
drive "$DA" 1 ""
[ "$(batch "$DA")" = "42 7" ] && ok "(a) BATCH=2 with a harness row FIRST still dispatches the product issue (#42)" \
                             || bad "(a) batch was '$(batch "$DA")' (want '42 7')"
[ -s "$DA/o/dispatch-invoked" ] && ok "(a) the batch reaches dispatch-merge.sh (one product slot, not a refusal)" \
                               || bad "(a) dispatch-merge.sh was never invoked"
case "$(probe "$DA")" in *42*7*|*7*42*) ok "(a) both issues are recorded in dispatched.txt" ;;
  *) bad "(a) dispatched.txt is '$(probe "$DA")'" ;; esac
grep -q 'product-floor unmet' "$DA/log" 2>/dev/null && bad "(a) a MET floor logged 'unmet'" \
                                                    || ok "(a) a met floor logs nothing"

# ══ (b) NO PRODUCT CANDIDATE → THE UNMET LINE WITH THE QUEUE TOKEN, BATCH OTHERWISE AS TODAY ═══
# Indicator (b) and contract 3. The batch must be exactly what the pre-#2054 loop produced (the
# merged FIFO, both rows, in order), and the reading must carry `queue=READ(203)(<age>)` so a
# harness-only box reads as a failing INTAKE rather than as "no product work".
echo; echo "── (b) an unmet floor is a READ line, not a silence, and the batch is unchanged ──"
DB="$(mk_case b)"
cands "$DB" '7
8'
prods "$DB" ''
drive "$DB" 1 ""
[ "$(batch "$DB")" = "7 8" ] && ok "(b) with no product candidate the batch is the merged FIFO, unchanged" \
                             || bad "(b) batch was '$(batch "$DB")' (want '7 8')"
[ -s "$DB/o/dispatch-merge.sh" ] && ok "(b) an unmet floor does NOT refuse the dispatch" \
                                || bad "(b) the sandbox lost its dispatch stub"
[ -s "$DB/o/dispatch-invoked" ] && ok "(b) the batch still reaches dispatch-merge.sh" \
                               || bad "(b) an unmet floor stopped the dispatch — it must only log"
grep -q '\[dispatch\] product-floor unmet (' "$DB/log" 2>/dev/null \
  && ok "(b) the unmet floor is logged with the issue's own wording" \
  || bad "(b) no product-floor line — log: $(tr '\n' '|' < "$DB/log" 2>/dev/null)"
grep -qE 'product-floor unmet \(reserved=1 admitted=0: .*\) queue=READ\(203\)\([0-9]+s?m?h?\)' "$DB/log" 2>/dev/null \
  && ok "(b) the unmet line carries the pool-read state WITH its age (READ(203)(…))" \
  || bad "(b) the unmet line does not carry queue_state_token — log: $(tr '\n' '|' < "$DB/log" 2>/dev/null)"
grep -q 'product queue is EMPTY' "$DB/log" 2>/dev/null \
  && ok "(b) an EMPTY product queue is named as an empty queue (not as an absent one)" \
  || bad "(b) the reason does not name an empty product queue"

# The ABSENT queue is a DIFFERENT fact (#1931's rule) and must not read as empty: a producer that
# predates this change has not written a split at all.
DBA="$(mk_case b-absent)"
cands "$DBA" '7'
rm -f "$DBA/o/candidates.product.txt"
drive "$DBA" 1 ""
grep -q 'no product queue: candidates.product.txt absent' "$DBA/log" 2>/dev/null \
  && ok "(b) an ABSENT product queue is named as absent, not as empty" \
  || bad "(b) absent and empty are not distinguished — log: $(tr '\n' '|' < "$DBA/log" 2>/dev/null)"
[ "$(batch "$DBA")" = "7" ] && ok "(b) an absent product queue degrades to the merged backlog exactly as before" \
                           || bad "(b) absent queue changed the batch: '$(batch "$DBA")'"

# ══ (c) MERGE-PRIORITY ENGAGED → THE FLOOR IS SKIPPED ═════════════════════════════════════════
# Indicator (c) and contract 1. `mp_reason` is driven first (the gate itself), then the whole
# shipped block is driven WITH the reason it produced: nothing may be batched, nothing dispatched,
# and the floor must not even BUILD its queue — it cannot delay a batch it never touches.
echo; echo "── (c) merge-priority wins outright: the floor sits after mp_reason ──"
MERGE_PRIORITY_AT=25
mp_hi="$(MERGE_PRIORITY_AT=25 bash -c '. "$1"; mp_reason 26 1 0 30' _ "$T/deps.sh")"
mp_lo="$(MERGE_PRIORITY_AT=25 bash -c '. "$1"; mp_reason 25 1 0 30' _ "$T/deps.sh")"
case "$mp_hi" in merge-priority*) ok "(c) mp_reason() engages above MERGE_PRIORITY_AT ($mp_hi)" ;;
  *) bad "(c) mp_reason() did not engage: '$mp_hi'" ;; esac
[ -z "$mp_lo" ] && ok "(c) mp_reason() stays empty at the threshold (25 is not > 25)" \
                || bad "(c) mp_reason() engaged at the boundary: '$mp_lo'"
DC="$(mk_case c)"
cands "$DC" '7
42'
prods "$DC" '42'
drive "$DC" 1 "$mp_hi"
[ ! -s "$DC/o/.batch" ] && ok "(c) merge-priority batches NOTHING (the floor cannot pre-empt the drain)" \
                       || bad "(c) merge-priority still batched '$(batch "$DC")'"
[ ! -e "$DC/o/dispatch-invoked" ] && ok "(c) merge-priority dispatches nothing" \
                                 || bad "(c) dispatch-merge.sh ran during a merge drain"
[ ! -e "$DC/o/.floor-queue" ] && ok "(c) the floor never even builds its queue during a drain" \
                             || bad "(c) the floor built .floor-queue despite merge-priority"
grep -q 'product-floor' "$DC/log" 2>/dev/null && bad "(c) a product-floor line appeared during a drain" \
                                              || ok "(c) no product-floor line is emitted during a drain"
grep -q 'skipped (merge-priority' "$DC/log" 2>/dev/null && ok "(c) the cycle names merge-priority as the reason" \
                                                        || bad "(c) the skip reason is not named — log: $(tr '\n' '|' < "$DC/log")"
# STRUCTURE, so a later hoist above the gate cannot pass: the gate's assignment precedes the block,
# and the block's own guard is `[ -z "$GATE_WHY" ]`.
_l_mp="$(grep -n 'GATE_WHY="\$(mp_reason' "$LOOP" | cut -d: -f1 | head -1)"
_l_pf="$(grep -n '^  # BEGIN product-floor' "$LOOP" | cut -d: -f1 | head -1)"
[ -n "$_l_mp" ] && [ -n "$_l_pf" ] && [ "$_l_mp" -lt "$_l_pf" ] \
  && ok "(c) the merge-priority gate is assigned BEFORE the floor block (line $_l_mp < $_l_pf)" \
  || bad "(c) the floor block is not downstream of the mp_reason assignment (mp=$_l_mp floor=$_l_pf)"
head -2 "$T/floor.sh" | grep -q '^  if \[ -z "\$GATE_WHY" \]; then' \
  && ok "(c) the block's first statement is the GATE_WHY guard (the drain branch encloses the floor)" \
  || bad "(c) the floor block is not guarded by GATE_WHY: $(head -2 "$T/floor.sh" | tr '\n' '|')"

# ══ (d) A COLLIDING PRODUCT CANDIDATE IS SKIPPED, NEVER FORCE-DISPATCHED ═══════════════════════
# Contract 2. A peer holds #42: the floor must NOT dispatch it, must NOT blacklist it, and must NOT
# let the refusal cost the batch — the harness slot still fills. The second half is the sharper
# property: the reserved slot goes to the next product candidate, i.e. the highest-priority
# DISPATCHABLE one, because a held issue is not dispatchable.
echo; echo "── (d) a peer-held product issue is skipped, and the harness slot still fills ──"
DD="$(mk_case d)"
seed_peer_claim "$DD" 42 || bad "(d) could not seed the peer's claim (the rest of this group is void)"
cands "$DD" '7
42'
prods "$DD" '42'
drive "$DD" 1 ""
case " $(batch "$DD") " in *" 42 "*) bad "(d) a HELD product issue was force-dispatched" ;;
  *) ok "(d) the held product issue stays OUT of the batch" ;; esac
[ "$(batch "$DD")" = "7" ] && ok "(d) the harness candidate fills the slots the refused product row did not" \
                           || bad "(d) batch was '$(batch "$DD")' (want the harness row '7')"
case " $(probe "$DD") " in *" 42 "*) bad "(d) a held issue was written to dispatched.txt (it must return next cycle)" ;;
  *) ok "(d) the held issue is NOT blacklisted — it returns next cycle" ;; esac
grep -q '#42 NOT dispatched' "$DD/log" 2>/dev/null && ok "(d) the refusal is logged against the issue" \
                                                    || bad "(d) the claim refusal is not logged"
grep -qE 'product-floor unmet \(reserved=1 admitted=0: .*claim gate' "$DD/log" 2>/dev/null \
  && ok "(d) the unmet reason names the claim gate, not a missing product queue" \
  || bad "(d) the unmet reason does not name the claim gate — log: $(tr '\n' '|' < "$DD/log")"
refs="$(git -C "$DD/repo" ls-remote origin 'refs/claims/issue-42' 2>/dev/null | wc -l | tr -d ' ')"
[ "$refs" = "1" ] && ok "(d) the peer's claim is untouched (exactly one claim ref remains)" \
                  || bad "(d) expected the peer's single claim ref, found '$refs'"

# The floor goes to the NEXT product candidate when the first is held.
DD2="$(mk_case d-next)"
seed_peer_claim "$DD2" 42 || bad "(d) could not seed the peer's claim for the scan-past case"
cands "$DD2" '7
42
43'
prods "$DD2" '42
43'
drive "$DD2" 1 ""
case " $(batch "$DD2") " in *" 43 "*) ok "(d) the reserved slot goes to the next PRODUCT candidate (#43), not a force" ;;
  *) bad "(d) the floor did not scan past the held row: batch '$(batch "$DD2")'" ;; esac
case " $(batch "$DD2") " in *" 42 "*) bad "(d) the held row still entered the batch" ;; *) : ;; esac
case " $(probe "$DD2") " in *" 43 "*) ok "(d) the substituted product issue is recorded as dispatched" ;;
  *) bad "(d) #43 was batched but not recorded" ;; esac

# ══ (e) THE TUNABLE: A GARBAGE VALUE REPAIRS TO 1, AND AN EXPLICIT 0 DISABLES THE FLOOR ═════════
# Guard-before-use, the same polarity as every other limit in the file: garbage must never repair to
# 0 (which would silently OPEN the gate) and an explicit 0 is a deliberate operator choice.
echo; echo "── (e) PRODUCT_FLOOR: garbage repairs to 1; 0 is a deliberate disable ──"
for bad_val in '4x' '09' '-1' '99999999999'; do
  DE="$(mk_case "e-$(printf '%s' "$bad_val" | tr -cd 'a-zA-Z0-9')")"
  cands "$DE" '7
42'
  prods "$DE" '42'
  drive "$DE" "$bad_val" ""
  [ "$(batch "$DE")" = "42 7" ] && ok "(e) PRODUCT_FLOOR='$bad_val' repairs to 1 (the floor is still ON)" \
                               || bad "(e) PRODUCT_FLOOR='$bad_val' opened the gate: batch '$(batch "$DE")'"
  grep -q 'product-floor unmet' "$DE/log" 2>/dev/null && bad "(e) PRODUCT_FLOOR='$bad_val' logged an unmet floor it had filled" \
                                                       || : ;
done
DZ="$(mk_case e-zero)"
cands "$DZ" '7
42'
prods "$DZ" '42'
drive "$DZ" 0 ""
[ "$(batch "$DZ")" = "7 42" ] && ok "(e) PRODUCT_FLOOR=0 disables the floor deliberately (merged FIFO order)" \
                             || bad "(e) PRODUCT_FLOOR=0 still reordered: batch '$(batch "$DZ")'"
grep -q 'product-floor unmet' "$DZ/log" 2>/dev/null && bad "(e) a deliberately disabled floor still logged 'unmet'" \
                                                   || ok "(e) a deliberately disabled floor logs nothing"
# A floor ABOVE the batch is clamped to the batch: it reserves every slot (three product rows cannot
# make a BATCH=2 batch hold three), and it does NOT log a miss it could never have filled..
DW="$(mk_case e-wide)"
cands "$DW" '7
42
43'
prods "$DW" '42
43'
drive "$DW" 5 ""
[ "$(batch "$DW")" = "42 43" ] && ok "(e) PRODUCT_FLOOR=5 with BATCH=2 clamps: both slots go to product rows" \
                             || bad "(e) a floor above BATCH moved the batch: '$(batch "$DW")'"
grep -q 'product-floor unmet' "$DW/log" 2>/dev/null && bad "(e) a floor clamped to BATCH still logged 'unmet'" \
                                                   || ok "(e) a floor clamped to BATCH logs nothing when it is filled"
# ... and when the clamped floor cannot be filled, the line reports the CLAMPED count, not the 5 the
# operator typed — the reading must describe the slots this batch had.
DW2="$(mk_case e-wide-short)"
cands "$DW2" '7
42'
prods "$DW2" '42'
drive "$DW2" 5 ""
grep -qE 'product-floor unmet \(reserved=2 admitted=1' "$DW2/log" 2>/dev/null \
  && ok "(e) an unfillable clamped floor reports the CLAMPED reservation (reserved=2, not 5)" \
  || bad "(e) the clamped reservation is not reported — log: $(tr '\n' '|' < "$DW2/log" 2>/dev/null)"

# ══ (f) THE dispatched.txt CHECK STAYS FIRST (contract 4) ═════════════════════════════════════
echo; echo "── (f) an already-dispatched issue is never re-offered, the floor included ──"
DF="$(mk_case f)"
cands "$DF" '7
42'
prods "$DF" '42'
printf '42\n' > "$DF/o/dispatched.txt"
drive "$DF" 1 ""
case " $(batch "$DF") " in *" 42 "*) bad "(f) an issue already in dispatched.txt was re-offered" ;;
  *) ok "(f) an issue already in dispatched.txt is skipped" ;; esac
_l_disp="$(grep -n 'grep -qx "\$ISS" "\$O/dispatched.txt"' "$T/floor.sh" | cut -d: -f1 | head -1)"
_l_cap="$(grep -n 'PROD_ADMITTED" -ge "\$floor_want"' "$T/floor.sh" | cut -d: -f1 | head -1)"
[ -n "$_l_disp" ] && [ -n "$_l_cap" ] && [ "$_l_disp" -lt "$_l_cap" ] \
  && ok "(f) the dispatched check precedes the floor's own bookkeeping in the loop" \
  || bad "(f) the floor's checks precede the dispatched check (disp=$_l_disp floor=$_l_cap)"

# ══ (g) THE PRODUCER SIDE: WHO IS PRODUCT, AND THE CLASS QUEUES ARE A PARTITION ══════════════
echo; echo "── (g) refresh-candidates.sh: classification, the checked class write, the partition ──"
if need "$T/classify.sh" "candidate_class()/repo_slug_valid() from refresh-candidates.sh"; then
  cls() { bash -c '. "$1"; shift; candidate_class "$@"' _ "$T/classify.sh" "$@"; }
  [ "$(cls daniel-ospina/tortoise)" = "product" ] && ok "(g) the default product repo classifies as product" \
                                                  || bad "(g) the default product repo did not classify: '$(cls daniel-ospina/tortoise)'"
  [ "$(cls daniel-ospina/agent-infra)" = "harness" ] && ok "(g) agent-infra classifies as harness" \
                                                     || bad "(g) agent-infra did not classify as harness"
  [ "$(PRODUCT_REPOS=' daniel-ospina/tortoise ' cls daniel-ospina/TORTOISE)" = "product" ] \
    && ok "(g) matching is case-insensitive (a repo slug is not case-significant)" \
    || bad "(g) case-insensitive matching failed"
  [ "$(PRODUCT_REPOS='acme/widget,daniel-ospina/tortoise' cls acme/widget)" = "product" ] \
    && ok "(g) PRODUCT_REPOS accepts a comma-separated list" || bad "(g) list parsing failed"
  # GARBAGE MUST REPAIR TO THE DEFAULT: 'nonsense' is not an owner/name, so the DEFAULT applies —
  # everything-as-harness would blind the floor and everything-as-product would make it always "met".
  [ "$(PRODUCT_REPOS='nonsense' cls daniel-ospina/tortoise)" = "product" ] \
    && ok "(g) a garbage PRODUCT_REPOS repairs to the DEFAULT (the floor is not blinded)" \
    || bad "(g) a garbage PRODUCT_REPOS did not repair to the default: '$(PRODUCT_REPOS=nonsense bash -c '. "$1"; candidate_class daniel-ospina/tortoise' _ "$T/classify.sh")'"
  [ "$(PRODUCT_REPOS='nonsense' cls daniel-ospina/agent-infra)" = "harness" ] \
    && ok "(g) ... and the default still leaves other repos as harness" \
    || bad "(g) the repaired default classified everything as product"
  [ "$(PRODUCT_REPOS='/tmp,/x/y/z,daniel-ospina/tortoise' cls /tmp)" = "harness" ] \
    && ok "(g) a malformed token is skipped, not matched" || bad "(g) a malformed token was matched"
  # ⛔ AN EMPTY SLUG MUST NOT MATCH EVERYTHING. `list` carries a leading space, so "empty slug" and
  # "every entry" are one bug apart — and the wrong direction here certifies a product slot that was
  # never filled. Found exactly this way: this loop body extracted standalone (OR unset) queued the
  # fixtures into candidates.PRODUCT.txt.
  [ "$(cls '')" = "harness" ] && ok "(g) an EMPTY/unknown repo classifies as harness, never as product" \
                              || bad "(g) an empty repo slug matched the product list: '$(cls '')'"
  [ "$(PRODUCT_REPOS='' cls daniel-ospina/tortoise)" = "product" ] \
    && ok "(g) an UNSET/blank PRODUCT_REPOS falls back to the default product repo" \
    || bad "(g) a blank PRODUCT_REPOS did not fall back to the default"
  # ⛔ ONE DEFAULT, TWO FILES. install.sh RENDERS PRODUCT_REPOS into the plist; refresh-candidates.sh
  # FALLS BACK to PRODUCT_DEFAULT_REPOS when it is unset (a manual run, or a box with no plist). If
  # those two ever disagree, the same pool classifies differently on the two paths and the floor is
  # blind on exactly one of them — so the default is asserted, not assumed to stay in step.
  _ins_default="$(grep -m1 -oE 'PRODUCT_REPOS="\$\{PRODUCT_REPOS:-[^}]*\}"' "$HERE/install.sh" | sed -E 's#.*:-([^}]*)\}"#\1#')"
  _ref_default="$(grep -m1 -oE '^PRODUCT_DEFAULT_REPOS="[^"]*"' "$REFRESH" | sed -E 's/^PRODUCT_DEFAULT_REPOS="([^"]*)"/\1/')"
  [ -n "$_ins_default" ] && [ "$_ins_default" = "$_ref_default" ] \
    && ok "(g) install.sh's rendered PRODUCT_REPOS default matches the classifier's fallback ($_ref_default)" \
    || bad "(g) the PRODUCT_REPOS default has two sources that disagree: install.sh='$_ins_default' classifier='$_ref_default'"
else
  bad "(g) could not extract the classifier"
fi

if need "$T/partition.sh" "the class-queue partition from refresh-candidates.sh"; then
  ok "refresh: the partition block is extractable from the shipped refresh"
  DP="$T/g-partition"; mkdir -p "$DP"
  printf '42\n99\n' > "$DP/candidates.txt"
  printf '42\n7\n' > "$DP/candidates.product.txt"      # 7 is STALE: no longer in the merged backlog
  printf '99\n7\n' > "$DP/candidates.harness.txt"
  ( O="$DP" EXIT_TRANSIENT=1 bash -c '. "$1"' _ "$T/partition.sh" ) >/dev/null 2>&1
  [ "$(tr '\n' ' ' < "$DP/candidates.product.txt" | sed 's/ *$//')" = "42" ] \
    && ok "(g) the product queue is re-derived as a SUBSET of the merged backlog (stale 7 dropped)" \
    || bad "(g) product queue is '$(tr '\n' ' ' < "$DP/candidates.product.txt")' (want '42')"
  [ "$(tr '\n' ' ' < "$DP/candidates.harness.txt" | sed 's/ *$//')" = "99" ] \
    && ok "(g) the harness queue drops the same dead number" \
    || bad "(g) harness queue is '$(tr '\n' ' ' < "$DP/candidates.harness.txt")' (want '99')"
  # An ABSENT class queue stays absent (absent != empty), so a reader can tell the two apart.
  DP2="$T/g-absent"; mkdir -p "$DP2"
  printf '42\n' > "$DP2/candidates.txt"
  ( O="$DP2" EXIT_TRANSIENT=1 bash -c '. "$1"' _ "$T/partition.sh" ) >/dev/null 2>&1
  [ ! -e "$DP2/candidates.product.txt" ] && [ ! -e "$DP2/candidates.harness.txt" ] \
    && ok "(g) an absent class queue is left absent (absent is a different fact from empty)" \
    || bad "(g) the partition created a class queue that never existed"
else
  bad "(g) could not extract the partition block"
fi

# The WRITE side: the class append is CHECKED and lands BEFORE `checked.txt` (a failed split is
# retryable), and the merged append is still first (the backlog is the authority).
_aw="$(grep -n 'candidates\.\$(candidate_class "\$OR")\.txt' "$REFRESH" | cut -d: -f1 | head -1)"
_am="$(grep -n '>> "\$O/candidates\.txt"' "$REFRESH" | cut -d: -f1 | head -1)"
_ac="$(grep -n '>> "\$O/checked\.txt"' "$REFRESH" | cut -d: -f1 | head -1)"
if [ -n "$_am" ] && [ -n "$_aw" ] && [ -n "$_ac" ] && [ "$_am" -lt "$_aw" ] && [ "$_aw" -lt "$_ac" ]; then
  ok "(g) the queue writes land merged → class → checked, so a failed split is retried (never blacklisted)"
else
  bad "(g) the queue-write order is wrong (merged=$_am class=$_aw checked=$_ac)"
fi
_cline="$(grep -F 'candidates.$(candidate_class "$OR").txt' "$REFRESH" | head -1)"
case "$_cline" in
  *'if ! printf'*'>> "$O/candidates.$(candidate_class "$OR").txt"'*)
    ok "(g) the class append is CHECKED (a candidate invisible to the floor cannot report success)" ;;
  *) bad "(g) the class append is unchecked: '$_cline'" ;;
esac
grep -q 'touch "\$O/checked.txt" "\$O/candidates.txt" "\$O/candidates.product.txt" "\$O/candidates.harness.txt"' "$REFRESH" \
  && ok "(g) both class queues are created by the producer (absence then means a STALE producer)" \
  || bad "(g) the class queues are not created by the producer"

# ══ (h) THE SHIPPED QUEUE LOOP WRITES THE RIGHT CLASS QUEUE, END TO END ═══════════════════════
# (g) proves the classifier and the partition in isolation; this drives the SHIPPED loop body (the
# `n=0` … `done < "$O/.pool"` region selftest.sh also extracts) with a CLEAN pre-flight stub, so the
# classification→filename wiring is measured on the code that ships, for both kinds of cell.
echo; echo "── (h) the shipped queue loop writes candidates.<class>.txt for the cell's own repo ──
"
awk '/^n=0$/{f=1} f{print} /^done < /{f=0}' "$REFRESH" > "$T/qloop.sh"
if need "$T/qloop.sh" "the shipped queue loop (from n=0) of refresh-candidates.sh"; then
  ok "refresh: the queue loop body is extractable from the shipped refresh"
  qdrive() {  # qdrive <dir> <OR>
    local d="$1"; mkdir -p "$d/fakesc/.venv/bin"
    printf '10\n20\n' > "$d/.pool"
    : > "$d/checked.txt"; : > "$d/candidates.txt"; : > "$d/dispatched.txt"
    printf '#!/bin/bash\necho "VERDICT: CLEAN"\n' > "$d/fakesc/.venv/bin/python"
    chmod +x "$d/fakesc/.venv/bin/python"
    ( O="$d" LIMIT=3 OR="$2" SC="$d/fakesc" PY="$d/fakesc/.venv/bin/python" \
      PREFLIGHT="$d/fakesc/tools/collision_preflight.py" bash "$T/qloop.sh" ) > "$d/out" 2>&1
  }
  QP="$T/h-product"; qdrive "$QP" daniel-ospina/tortoise
  [ "$(tr '\n' ' ' < "$QP/candidates.product.txt" 2>/dev/null | sed 's/ *$//')" = "10 20" ] \
    && ok "(h) a product-repo cell queues into candidates.product.txt" \
    || bad "(h) product cell wrote product queue '$(tr '\n' ' ' < "$QP/candidates.product.txt" 2>/dev/null)'"
  [ ! -s "$QP/candidates.harness.txt" ] 2>/dev/null \
    && ok "(h) a product-repo cell writes nothing into the harness queue" \
    || bad "(h) a product-repo cell wrote the harness queue"
  [ "$(tr '\n' ' ' < "$QP/candidates.txt" 2>/dev/null | sed 's/ *$//')" = "10 20" ] \
    && ok "(h) the merged candidates.txt is still written, unchanged (the fallback)" \
    || bad "(h) the merged backlog was not written"
  QH="$T/h-harness"; qdrive "$QH" daniel-ospina/agent-infra
  [ "$(tr '\n' ' ' < "$QH/candidates.harness.txt" 2>/dev/null | sed 's/ *$//')" = "10 20" ] \
    && ok "(h) a harness-repo cell queues into candidates.harness.txt (its product queue stays empty)" \
    || bad "(h) harness cell wrote harness queue '$(tr '\n' ' ' < "$QH/candidates.harness.txt" 2>/dev/null)'"
  [ ! -s "$QH/candidates.product.txt" ] 2>/dev/null \
    && ok "(h) a harness-repo cell leaves the product queue empty — which is what the floor must REPORT" \
    || bad "(h) a harness-repo cell queued product work it does not have"
else
  bad "(h) could not extract the queue loop body"
fi

# ══ (i) THE FLOOR NEVER SHRINKS A BATCH, AND ONLY DRAWS ON VETTED ROWS ═════════════════════════
# Three defects found in independent verification (2026-10-19) of the first implementation, each a
# regression of the CONTRACT rather than of the wording, and none of which the groups above caught
# because every one of their fixtures mixes a harness row in:
#   (i.1) THROUGHPUT. On a product cell EVERY queued row is product work (a candidate's class is the
#         cell's own repo), so `candidates.product.txt` == `candidates.txt`. An implementation that
#         drops the FIFO's product rows from the remainder and stands them all down once the floor is
#         met dispatched 1 of BATCH=2 per cycle — a 50% cut to the throughput #2054 was measured to
#         fix, i.e. a floor that became a quota.
#   (i.2) ORDER. The remainder of the batch must be the merged FIFO's own order ("exactly as today",
#         the issue's step 2): the row in slot floor+1 is the row the FIFO would have offered, and it
#         is never demoted below a lower-priority row just because it is product work.
#   (i.3) ELIGIBILITY. A row in the product queue that the merged backlog does not hold has had NO
#         pre-flight verdict from this pass; the reserve must be intersected with `candidates.txt`,
#         never dispatched on the floor's word.
echo; echo "── (i) the floor never shrinks a batch, keeps the FIFO's order, and only draws on vetted rows ──"
# (i.1) product-only pool, floor=1 of BATCH=2
DI="$(mk_case i-product-only)"
cands "$DI" '42
43'
prods "$DI" '42
43'
drive "$DI" 1 ""
[ "$(batch "$DI")" = "42 43" ] && ok "(i.1) a PRODUCT-ONLY pool still fills BATCH=2 (the floor is not a quota)" \
                               || bad "(i.1) a product-only pool dispatched '$(batch "$DI")' of BATCH=2 — throughput halved"
# (i.2) the remainder is the merged FIFO's next row
DI2="$(mk_case i-fifo-order)"
cands "$DI2" '42
43
7'
prods "$DI2" '42
43'
drive "$DI2" 1 ""
[ "$(batch "$DI2")" = "42 43" ] && ok "(i.2) slot 2 is the row the merged FIFO would have offered (#43), not a demoted one" \
                                || bad "(i.2) the remainder is not the FIFO order: '$(batch "$DI2")' (want '42 43')" 
# (i.3) a product row with no verdict this pass
DI3="$(mk_case i-no-verdict)"
cands "$DI3" '7'
prods "$DI3" '42'
drive "$DI3" 1 ""
case " $(batch "$DI3") " in *" 42 "*) bad "(i.3) a product row ABSENT from the merged backlog was dispatched (no pre-flight verdict)" ;;
  *) ok "(i.3) a product row the merged backlog does not hold is NOT dispatched on the floor's word" ;; esac
grep -q 'has a VERDICT for' "$DI3/log" 2>/dev/null \
  && ok "(i.3) the unmet line names the missing VERDICT, not a missing product queue" \
  || bad "(i.3) the reason misreports a stale product queue — log: $(tr '\n' '|' < "$DI3/log" 2>/dev/null)"
# ... and the refused row is not claim-attempted a second time by the FIFO region
DI4="$(mk_case i-single-claim)"
seed_peer_claim "$DI4" 42 || bad "(i.4) could not seed the peer's claim"
cands "$DI4" '7
42'
prods "$DI4" '42'
drive "$DI4" 1 ""
_n_attempts="$(grep -c 'NOT dispatched' "$DI4/log" 2>/dev/null | tr -d ' ')"
[ "${_n_attempts:-0}" -le 1 ] && ok "(i.4) a refused product row is claim-attempted ONCE per cycle (the FIFO repeats it)" \
                            || bad "(i.4) the refused row was claim-attempted $_n_attempts times in one cycle"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "  PASS=$PASS FAIL=0 — product-work floor contract holds"
else
  echo "  PASS=$PASS FAIL=$FAIL"; exit 1
fi
