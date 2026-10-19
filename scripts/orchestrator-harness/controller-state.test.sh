#!/usr/bin/env bash
# controller-state.test.sh — the singleton, the state-dir resolver, and threshold provenance
# (agent-infra#2095).
#
# WHAT THIS SUITE IS FOR. On 2026-10-18 a proof copy of `orch-loop.sh` ran for 5 h 15 m beside the
# launchd controller. Both resolved `O="${O:-$HOME/orchestrator}"`, so they shared ONE state dir and
# ONE log, and the proof copy gated dispatch at its OWN derived `MAX_LOAD=100` while the plist said
# 250. Three separate defects, and every check below drives the SHIPPED code on the failure the
# incident actually produced:
#
#   1. a second instance must REFUSE, loudly and non-zero (was `exit 0` after a bare `kill -0`);
#   2. a copy that is not the production install must NOT reach production state by default;
#   3. `[cap]` must say WHICH instance and WHERE its MAX_LOAD came from.
#
# ⛔ THE POINT OF MOST OF THESE CHECKS IS THE POLARITY. A guard that refuses everything passes a
# "refuses" test; a guard that refuses nothing passes a "co-runs" test. So each refusal has a
# matching ALLOW (a stale record IS reclaimed, a free lock IS acquired), and each allow has a
# matching refusal (a live holder is NOT reclaimed, an unreadable record is NOT read as free).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUBJECT="$HERE/controller-state.sh"
LOOP="$HERE/orch-loop.sh"
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  ✅ %s\n' "$1"; PASS=$((PASS+1));
  else printf '  ❌ %s\n' "$1"; FAIL=$((FAIL+1)); fi
}
TMP="$(mktemp -d)"
HOLDER_PIDS=""
cleanup() {
  for p in $HOLDER_PIDS; do kill -TERM "$p" 2>/dev/null || true; done
  rm -rf "$TMP"
}
trap cleanup EXIT

echo "==> controller-state self-test ($HERE)"

[ -s "$SUBJECT" ] && bash -n "$SUBJECT"; rc=$?
ck "controller-state.sh exists and parses" $rc
# It is SOURCED by the controller, never executed: an execute-only helper would leave every function
# unset at the call site and `orch-loop.sh` would refuse to start (exit 78).
grep -qE '^\s*\.\s+"\$ORC_GUARD"' "$LOOP"; rc=$?
ck "orch-loop.sh SOURCES the guard from \$ORC_GUARD (and fails closed without it)" $rc

mkdir -p "$TMP/home" "$TMP/proof" "$TMP/tmpd"
cp "$SUBJECT" "$TMP/proof/controller-state.sh"

# ⛔ SOURCED IN A SUBSHELL PER SECTION. `orc_state_pick` mutates ORC_STATE_RESOLVED/ORC_STATE_SRC
# and the singleton mutates ORC_HOLDER_*, so a shared shell would let one check's leftovers answer
# the next one — a stale-flag false pass, in the suite that exists to catch exactly that shape.
run_in() { # run_in <HOME> <snippet>
  ( HOME="$1"; TMPDIR="$TMP/tmpd"; unset ORC_STATE_DIR O; . "$SUBJECT"; eval "$2" )
}

# ── 1) THE STATE DIRECTORY: explicit wins, production only from the production install ─────────
got="$(run_in "$TMP/home" 'orc_state_pick "$TMP/proof/orch-loop.sh"; printf "%s|%s" "$ORC_STATE_RESOLVED" "$ORC_STATE_SRC"')"
case "$got" in
  "$TMP/tmpd/orc-state-proof|derived:isolated"*)
    ck "a proof copy defaults to an ISOLATED state dir (never \$HOME/orchestrator): $got" 0 ;;
  *) ck "a proof copy defaults to an ISOLATED state dir (got: $got)" 1 ;;
esac

# The provenance must be readable in the CALLER's shell, not only inside `$( )`. That is the bug this
# shape exists for: `O="$(orc_state_resolve …)"` runs in a subshell, and every `[cap]` line printed
# `state_src=` empty until it was split into a global-setting function + a printing wrapper.
got="$(run_in "$TMP/home" 'orc_state_pick "$TMP/proof/orch-loop.sh" >/dev/null; printf "%s" "$ORC_STATE_SRC"')"
[ -n "$got" ] && case "$got" in derived:isolated*) rc=0 ;; *) rc=1 ;; esac
ck "orc_state_pick sets ORC_STATE_SRC in the CALLER's shell (no subshell loss) — '$got'" ${rc:-1}

got="$(run_in "$TMP/home" 'ORC_STATE_DIR=/srv/explicit; orc_state_pick /x/orch-loop.sh; printf "%s|%s" "$ORC_STATE_RESOLVED" "$ORC_STATE_SRC"')"
[ "$got" = "/srv/explicit|env:ORC_STATE_DIR" ]; rc=$?
ck "ORC_STATE_DIR (the canonical name) wins: $got" $rc

got="$(run_in "$TMP/home" 'O=/srv/legacy; orc_state_pick /x/orch-loop.sh; printf "%s|%s" "$ORC_STATE_RESOLVED" "$ORC_STATE_SRC"')"
[ "$got" = "/srv/legacy|env:O(legacy)" ]; rc=$?
ck "the LEGACY O still wins (every deployed plist sets it): $got" $rc

got="$(run_in "$TMP/home" 'ORC_STATE_DIR=/srv/explicit; printf "%s" "$(orc_state_resolve /x/orch-loop.sh)"')"
[ "$got" = "/srv/explicit" ]; rc=$?
ck "orc_state_resolve (the printing wrapper) returns the same answer: $got" $rc

# The production copy — the one that LIVES in $HOME/orchestrator — keeps the production path.
mkdir -p "$TMP/home/orchestrator"
cp "$SUBJECT" "$TMP/home/orchestrator/controller-state.sh"
got="$(run_in "$TMP/home" 'orc_state_pick "$TMP/home/orchestrator/orch-loop.sh"; printf "%s|%s" "$ORC_STATE_RESOLVED" "$ORC_STATE_SRC"')"
[ "$got" = "$TMP/home/orchestrator|default:production-install" ]; rc=$?
ck "the production install still resolves to \$HOME/orchestrator: $got" $rc

# ── 2) THE SINGLETON ──────────────────────────────────────────────────────────────────────────
# A live holder whose INVOCATION is `orch-loop.sh`. The fixture must carry that NAME: the predicate
# is argv-shape based, not a substring, and naming it anything else would test a different rule.
mkdir -p "$TMP/inst"
cat > "$TMP/inst/orch-loop.sh" <<'FIX'
#!/bin/bash
# test fixture holder — the REAL guard decides, this only claims and sleeps
. "$ORC_GUARD_TEST"
orc_singleton_acquire "$1" "${2:-}" || exit 75
echo "acquired $$"
while :; do sleep 1; done
FIX
chmod +x "$TMP/inst/orch-loop.sh"
ORC_GUARD_TEST="$SUBJECT" "$TMP/inst/orch-loop.sh" "$TMP/inst/.orch.lock" "$TMP/inst" > "$TMP/holder.out" 2>&1 &
HPID=$!
HOLDER_PIDS="$HOLDER_PIDS $HPID"
for _i in 1 2 3 4 5 6 7 8 9 10; do grep -q '^acquired' "$TMP/holder.out" 2>/dev/null && break; sleep 0.2; done

got="$(run_in "$TMP/home" "orc_singleton_acquire '$TMP/inst/.orch.lock' '$TMP/inst'; printf 'rc=%s pid=%s why=%s' \$? \"\$ORC_HOLDER_PID\" \"\$ORC_HOLDER_WHY\"")"
case "$got" in
  "rc=1 pid=$HPID why=pid $HPID is a live orch-loop.sh invocation")
    ck "a SECOND instance is REFUSED by a live controller, naming its pid: $got" 0 ;;
  *) ck "a SECOND instance is REFUSED by a live controller (got: $got)" 1 ;;
esac

# ⛔ AN ALIVE PID THAT IS NOT A CONTROLLER IS NOT PROOF OF OWNERSHIP — but it is not proof of
# staleness either. With no age evidence the guard must FAIL CLOSED (2 = UNJUDGED), never reclaim:
# two controllers sharing one state dir is the incident.
sleep 60 & SPID=$!
HOLDER_PIDS="$HOLDER_PIDS $SPID"
# ⛔ `started=` MUST BE RECENT, NOT ANCIENT. "Recycled" is provable only when the process began
# AFTER the record was written; a record written after the process started proves nothing, which is
# the fail-CLOSED case this check is about. (An ancient `started` would make the age test TRUE and
# reclaim the lock — the opposite arms, and a test that cannot tell them apart checks neither.)
printf 'orc-v1 pid=%s started=%s host=x\nstate=%s' "$SPID" "$(date +%s)" "$TMP/inst" > "$TMP/inst/.orch.other"
got="$(run_in "$TMP/home" "orc_singleton_acquire '$TMP/inst/.orch.other' '$TMP/inst'; printf 'rc=%s why=%s' \$? \"\$ORC_HOLDER_WHY\"")"
# ⛔ THE CONTRACT IS rc=1 (HELD, refuse) HERE — `2` is reserved for a record that cannot be READ at
# all. What matters is that it is NON-ZERO and that the record survived: a reclaim on an unproven
# holder is how two controllers get one state dir.
case "$got" in
  "rc=1 why="*"not an orch-loop.sh invocation"*) grep -q "^orc-v1 pid=$SPID " "$TMP/inst/.orch.other" && r2=0 || r2=1 ;;
  *) r2=1 ;;
esac
ck "an ALIVE non-controller pid is REFUSED and NOT reclaimed: $got" ${r2:-1}

# A RECYCLED pid IS provable — the process began AFTER the record was written — and must self-heal.
printf 'orc-v1 pid=%s started=1 host=x\nstate=%s' "$SPID" "$TMP/inst" > "$TMP/inst/.orch.recycled"
got="$(run_in "$TMP/home" "orc_singleton_acquire '$TMP/inst/.orch.recycled' '$TMP/inst'; printf 'rc=%s' \$?")"
[ "$got" = "rc=0" ]; rc=$?
ck "a RECYCLED pid (began after the record) is reclaimed, not blocked: $got" $rc

# A DEAD pid is stale by definition — and the reclaim must also OWN the record afterwards.
printf 'orc-v1 pid=999999999 started=1 host=x\nstate=%s' "$TMP/inst" > "$TMP/inst/.orch.dead"
got="$(run_in "$TMP/home" "orc_singleton_acquire '$TMP/inst/.orch.dead' '$TMP/inst'; printf 'rc=%s pid_in_record=%s' \$? \"\$(sed -n 's/^orc-v1 pid=//p' '$TMP/inst/.orch.dead' | cut -d' ' -f1)\"")"
[ "$got" = "rc=0 pid_in_record=$$" ]; rc=$?
# ⛔ `$$` inside `run_in`'s eval is the SUBSHELL's pid, and the record was written by that subshell —
# so the check is that the record names a LIVE pid, not a fixed number.
case "$got" in
  "rc=0 pid_in_record="*) [ "$(printf '%s' "$got" | sed 's/.*pid_in_record=//')" -gt 0 ] && rc=0 || rc=1 ;;
  *) rc=1 ;;
esac
ck "a DEAD pid is reclaimed and the record is rewritten by the new owner: $got" $rc

# ⛔ AN UNREADABLE RECORD IS NOT A FREE LOCK. Garbage, an empty file, and a truncated one all look
# identical to "somebody is deciding right now" — reclaiming them is how two controllers co-run.
: > "$TMP/inst/.orch.empty"
got="$(run_in "$TMP/home" "orc_singleton_acquire '$TMP/inst/.orch.empty' '$TMP/inst'; printf 'rc=%s' \$?")"
[ "$got" = "rc=2" ]; rc=$?
ck "an EMPTY/unreadable record fails CLOSED (rc=2), never 'the lock is free': $got" $rc

# Release must be OWNERSHIP-SCOPED: removing somebody else's record is how a later instance starts
# believing it is the first.
printf 'orc-v1 pid=%s started=1 host=x\nstate=x' "$SPID" > "$TMP/inst/.orch.foreign"
(run_in "$TMP/home" "orc_singleton_release '$TMP/inst/.orch.foreign'") >/dev/null 2>&1
[ -f "$TMP/inst/.orch.foreign" ]; rc=$?
ck "release does NOT remove a record this process did not write" $rc

# And a lock this process DOES own is released by the same call.
(run_in "$TMP/home" "orc_singleton_acquire '$TMP/inst/.orch.mine' '$TMP/inst' >/dev/null; orc_singleton_release '$TMP/inst/.orch.mine'") >/dev/null 2>&1
[ ! -e "$TMP/inst/.orch.mine" ]; rc=$?
ck "release DOES remove this process's own record" $rc

# ── 3) THE WIRING: the REAL orch-loop.sh must exit non-zero on a held state dir ───────────────
# ⛔ THE FIXTURE ABOVE PROVES THE GUARD; IT DOES NOT PROVE THE CONTROLLER USES IT. A grep for
# `orc_singleton_acquire` passes on a call site whose refusal returns 0 (the old behaviour). So the
# real script is executed against a held state dir and its EXIT CODE is asserted.
DEPLOY="$TMP/deploy"
mkdir -p "$DEPLOY/logs" "$DEPLOY/state"
cp "$HERE"/*.sh "$DEPLOY"/ 2>/dev/null
mkdir -p "$TMP/repo"
git -C "$TMP/repo" init -q 2>/dev/null || true
cat > "$DEPLOY/orch-loop.sh.holder" <<'FIX'
#!/bin/bash
# a LIVE holder for the real controller's state dir — named orch-loop.sh so the
# argv-shape predicate under test recognises it (see controller-state.sh)
. "$ORC_GUARD_TEST"
orc_singleton_acquire "$1" "$2" || exit 75
echo "acquired $$"
while :; do sleep 1; done
FIX
cp "$DEPLOY/orch-loop.sh.holder" "$DEPLOY/holder-orch-loop.sh"
rm -f "$DEPLOY/orch-loop.sh.holder"
# ...and the holder must be INVOKED under the name orch-loop.sh: copy it to a directory of its own.
mkdir -p "$TMP/holderbin"
cp "$DEPLOY/holder-orch-loop.sh" "$TMP/holderbin/orch-loop.sh"
chmod +x "$TMP/holderbin/orch-loop.sh"
ORC_GUARD_TEST="$SUBJECT" "$TMP/holderbin/orch-loop.sh" "$DEPLOY/.orch.lock" "$DEPLOY" > "$TMP/holder2.out" 2>&1 &
H2=$!
HOLDER_PIDS="$HOLDER_PIDS $H2"
for _i in 1 2 3 4 5 6 7 8 9 10; do grep -q '^acquired' "$TMP/holder2.out" 2>/dev/null && break; sleep 0.2; done

# A SEPARATE copy of the controller, so this is genuinely a second instance (the deployed copy the
# plist runs is the first). REPO must exist or the controller refuses at its own repo guard, which
# would make this check pass for the wrong reason.
SECOND="$TMP/second"
mkdir -p "$SECOND"
cp "$HERE"/*.sh "$SECOND"/ 2>/dev/null
out="$(cd "$SECOND" && REPO="$TMP/repo" ORC_STATE_DIR="$DEPLOY" bash "$SECOND/orch-loop.sh" 2>&1)"
rc=$?
case "$rc" in
  75) { grep -q 'REFUSING TO START' <<<"$out" && grep -q "held by instance pid=$H2" <<<"$out"; }; rc=$? ;;
  *) echo "      exit=$rc output=$(printf '%s' "$out" | head -3)"; rc=1 ;;
esac
ck "the REAL orch-loop.sh REFUSES to co-run (exit 75, naming the holder pid $H2)" $rc
# ...and the refusal is RECORDED, so an operator finds it in the log rather than only on stderr.
grep -q '^\[singleton\] refused' "$DEPLOY/logs/orch-loop.log" 2>/dev/null; rc=$?
ck "the refusal is written to the state dir's log as [singleton]" $rc
# ...and it did NOT touch the holder's record (a refusal that deletes the lock is worse than none).
grep -q "^orc-v1 pid=$H2 " "$DEPLOY/.orch.lock" 2>/dev/null; rc=$?
ck "the refused instance leaves the holder's lock record intact" $rc

# ── 4) THRESHOLD PROVENANCE: which value is in force, and where it came from ─────────────────
got="$( ( unset MAX_LOAD; . "$SUBJECT"; orc_limit_src MAX_LOAD derived ) )"
[ "$got" = "derived" ]; rc=$?
ck "no value supplied -> src=derived: $got" $rc
got="$( ( MAX_LOAD=250; . "$SUBJECT"; orc_limit_src MAX_LOAD derived ) )"
[ "$got" = "env" ]; rc=$?
ck "a shell export -> src=env (distinguishable from the plist): $got" $rc
got="$( ( MAX_LOAD=250; ORC_CONTROLLER_ORIGIN=plist; . "$SUBJECT"; orc_limit_src MAX_LOAD derived ) )"
[ "$got" = "plist(plist)" ]; rc=$?
ck "a plist-rendered value -> src=plist(<origin>): $got" $rc
got="$( ( MAX_LOAD=; . "$SUBJECT"; orc_limit_src MAX_LOAD derived ) )"
[ "$got" = "derived" ]; rc=$?
ck "an EMPTY value means 'not supplied' (the derivation runs): $got" $rc

# ⛔ `[cap]` MUST PRINT BOTH. The incident's log carried `[cap] load=158/100` and nothing else, so
# which instance gated at 100 could only be INFERRED from arithmetic. A source grep is weak, so it
# is paired with the functional checks above: this one only asserts the line still CARRIES the
# fields, which is the part no unit test can see.
CAPLN="$(grep -m1 '^\s*echo "\[cap\]' "$LOOP")"
# ⛔ `grep -F`, not a `case` glob: `[cap]` in a glob is a CHARACTER CLASS, so the pattern matched
# nothing and this check failed on a line that carried every field.
{ grep -qF '[cap] ctl=$ORC_INSTANCE' <<<"$CAPLN" \
  && grep -qF 'src=$MAX_LOAD_SRC' <<<"$CAPLN" \
  && grep -qF 'state_src=$ORC_STATE_SRC' <<<"$CAPLN"; }; rc=$?
ck "[cap] prints the INSTANCE (ctl=), the MAX_LOAD source, and the state-dir source" $rc
# ...and the instance id is latched once, so two lines from one run cannot disagree about WHO.
got="$( ( . "$SUBJECT"; orc_self_describe /s >/dev/null; a="$ORC_INSTANCE"; sleep 1; orc_self_describe /s >/dev/null; [ "$a" = "$ORC_INSTANCE" ] && printf stable || printf DRIFTED ) )"
[ "$got" = "stable" ]; rc=$?
ck "orc_self_describe latches ONE identity for the life of the process: $got" $rc

# ── 5) the process-identity predicates, both ways ─────────────────────────────────────────────
( . "$SUBJECT"; orc_pid_is_controller $$ ) && rc=0 || rc=1
ck "orc_pid_is_controller rejects this (non-orch-loop) invocation" $((1 - rc))
( . "$SUBJECT"; orc_pid_is_controller 999999999 ) && rc=0 || rc=1
ck "orc_pid_is_controller rejects a dead pid" $((1 - rc))
# "Cannot tell" is an ARM OF ITS OWN. Folding it into either verdict makes an unreadable age the
# strongest possible evidence of ownership (see controller-state.sh).
( . "$SUBJECT"; orc_pid_began_after "$SPID" "not-an-epoch" ); rc=$?
[ "$rc" -eq 2 ]; rc=$?
ck "orc_pid_began_after returns 2 (cannot tell) for an unparseable epoch, never 0/1" $rc
( . "$SUBJECT"; orc_pid_began_after 999999999 "$(date +%s)" ); rc=$?
[ "$rc" -eq 2 ]; rc=$?
ck "orc_pid_began_after returns 2 (cannot tell) when the process's start cannot be read" $rc

echo
echo "==> controller-state: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
