#!/usr/bin/env bash
# claim-exclusion.test.sh — THE MEASUREMENT behind agent-infra#1908.
#
# #1908 is conditional: retire the `SCOPE=own` partition only once a claim is *demonstrated* to
# exclude a concurrent dispatch, and only for the operations that tolerate at-least-once. The claim
# registry existing (#1850) is not that demonstration; this file is.
#
# WHAT IT ANSWERS, per operation class, in the issue's own question: when a SECOND holder takes the
# same claimable item inside the same lease window, is it REFUSED — and if not, what does it do?
#
#   M1  dispatch      — `claim_issue_acquire` (key `refs/claims/issue-<N>`), N processes released
#                       at a barrier and then staggered by a few ms (see the racer's note).
#   M2  review/record — `claim_acquire` (key `refs/claims/<PR>-<sha12>`), same shape.
#   M3  landing       — the SAME PR offered at TWO DIFFERENT heads. The key is content-addressed on
#                       the head, so this is the row where the claim cannot express "this PR" and
#                       must be MEASURED rather than assumed.
#   M4  fencing       — the loser of a race tries to RELEASE the winner's claim. A stale holder that
#                       can delete the winner's claim is not an exclusion mechanism.
#   M5  the fence itself — a writer holding a stale view of a MOVED branch: a leased push that would
#                       otherwise fast-forward, and a plain push that would not.
#
# ⛔ WHAT THIS IS, AND WHAT IT IS NOT. It is N INDEPENDENT PROCESSES released together against a real
# `git receive-pack` — the same CAS primitive the fleet uses, raced for real. It is NOT the
# three-machine fleet: the default origin is a throwaway bare repo in the sandbox, so this measures
# the ref-update atomicity, not the network. That limit is stated again in README §7.2d where the
# table this file prints is recorded, and it is why `--origin live` exists (see below).
#
# `--origin live` runs the SAME races against THIS checkout's real origin, in a `$$`-scoped claim
# namespace, so the measurement can be repeated on the real remote. It is opt-in and never the
# default, because a suite that needs a network remote cannot be a CI shard (the same reason
# test-claims.sh and test-crossbox.sh are excluded from run-bash-shards.sh).
#
# ⛔ THE TABLE IN README §7.2d IS COPIED FROM THIS FILE'S OUTPUT. If a row here changes polarity the
# suite fails and names the row, so the doc cannot silently go stale — including in the good
# direction (a fixed per-PR gap turns M3 red and says "retire the landing row").
#
# ⛔ ONE THING THIS DOES NOT MEASURE, SAID PLAINLY: `gh pr merge` on a moved head. That needs GitHub.
# The landing row is reported here as a MEASURED claim-keying gap (M3) plus a code-level statement
# about what the merge path then does; it is never presented as a measured merge outcome.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELF="$HERE/$(basename "${BASH_SOURCE[0]}")"
CLAIMS_SH="${CLAIMS_SH:-$HERE/claims.sh}"
LAPS="${LAPS:-3}"        # laps per racy row — one lap can pass by luck
RACERS="${RACERS:-6}"    # simultaneous holders per lap
STAGGER_MS="${STAGGER_MS:-3}"  # per-racer release offset in ms (see the racer's note on why)

# ── the RACER role ────────────────────────────────────────────────────────────────────────────
# Re-exec'd as a separate PROCESS so the concurrency is real: a subshell in one process would share
# `$$`, so every "box" would present the same owner, and the whole point is two DISTINCT owners.
#
# argv: <box-dir> <box-id> <barrier-fifo> <out-file> <op> <op-args...>
# The barrier is a per-racer FIFO: each racer blocks in `read` until the parent opens it for
# writing, so all of them are released within microseconds of each other. A `sleep`-poll barrier was
# tried first and abandoned — its dispersion exceeded the whole push, so the race never happened and
# the suite reported EXACTLY ONE WINNER for a reason that had nothing to do with the CAS.
if [ "${CLAIM_EXCLUSION_AS_RACER:-0}" = "1" ]; then
  box="$1"; boxid="$2"; gofifo="$3"; out="$4"; op="$5"; shift 5
  # ⛔ ASSIGNED IN SEPARATE STATEMENTS, NOT AS A PREFIX. A variable assignment prefixed to `.`
  # is a TEMPORARY environment for that one command, and bash restores it afterwards — the functions
  # claims.sh defines would then see CLAIM_REPO unset and `_git` dies under `set -u`. See
  # refresh-scout.test.sh's `mk_issue_claim` for the same trap.
  CLAIM_OWNER_HOST="$boxid"; export CLAIM_OWNER_HOST
  CLAIM_REPO="$box"; export CLAIM_REPO
  cd "$box" || { printf '90\tcould not cd to %s\t\n' "$box" > "$out"; exit 0; }
  read -r _ < "$gofifo" || { printf '90\tbarrier read failed\t\n' > "$out"; exit 0; }
  # ⛔ A DELIBERATE, TINY STAGGER — and it is what makes this a cross-box measurement rather than a
  # ref-LOCK measurement. Released in the same microsecond, every `git push` contends for the same
  # `<ref>.lock` on the remote, so the LOSERS are refused by git's lock and never reach the CAS at
  # all: measured by forcing the create push (`--force`) and still getting exactly one winner, which
  # would have let a defeated CAS report EXCLUDES. Two boxes are never that synchronised (network
  # latency alone staggers them), so each racer waits `n * $CLAIM_EXCLUSION_STAGGER` ms after the
  # barrier and the ref update actually happens, in order, one at a time — which is the case the
  # claim's CAS has to handle. 0 restores the fully-simultaneous (lock-dominated) form.
  [ "${CLAIM_EXCLUSION_STAGGER:-0}" = "0" ] || sleep "$CLAIM_EXCLUSION_STAGGER"
  # shellcheck source=/dev/null
  . "$CLAIMS_SH"
  case "$op" in
    issue) claim_issue_acquire "$box" "$1" "${2:-600}" >/dev/null; rc=$? ;;
    pr)    claim_acquire "$box" "$1" "$2" "${3:-600}" >/dev/null; rc=$? ;;
    *)     printf '91\tunknown racer op %s\t\n' "$op" > "$out"; exit 0 ;;
  esac
  printf '%s\t%s\t%s\n' "$rc" "${CLAIM_RESULT:-<no result>}" "${CLAIM_COMMIT:-}" > "$out"
  exit 0
fi

[ -f "$CLAIMS_SH" ] || { echo "❌ missing $CLAIMS_SH"; exit 2; }

PASS=0; FAIL=0
ok()  { echo "  ✅ $1"; PASS=$((PASS+1)); }
bad() { echo "  ❌ $1"; FAIL=$((FAIL+1)); }
ck() { # ck <label> <expected-regex> <actual>
  # here-string, not `printf … | grep -q`: under pipefail grep exits at its first match, the writer
  # takes SIGPIPE, and the pipeline reports 141 instead of a match (#841).
  if grep -q "$2" <<<"$3"; then ok "$1"; else bad "$1 — expected /$2/ in: $3"; fi
}

# ── arguments ────────────────────────────────────────────────────────────────────────────────
ORIGIN_MODE=fake
while [ $# -gt 0 ]; do
  case "$1" in
    --origin) ORIGIN_MODE="${2:-fake}"; shift 2 ;;
    --laps)   LAPS="${2:-3}"; shift 2 ;;
    --racers) RACERS="${2:-6}"; shift 2 ;;
    --stagger-ms) STAGGER_MS="${2:-3}"; shift 2 ;;
    -h|--help)
      sed -n '2,45p' "$SELF" | sed 's/^# \{0,1\}//'
      echo
      echo "usage: ${0##*/} [--origin fake|live] [--laps N] [--racers N] [--stagger-ms MS]"
      echo "  fake (default)  a throwaway bare repo in the sandbox — hermetic, the CI form"
      echo "  live            THIS checkout's origin, in a \$\$-scoped claim namespace (needs network)"
      exit 0 ;;
    *) echo "[fatal] unknown argument: $1" >&2; exit 2 ;;
  esac
done
case "$ORIGIN_MODE" in fake|live) ;; *) echo "[fatal] --origin must be fake|live (got '$ORIGIN_MODE')" >&2; exit 2 ;; esac
case "$LAPS" in ''|*[!0-9]*|0) echo "[fatal] --laps must be a positive integer (got '$LAPS')" >&2; exit 2 ;; esac
case "$RACERS" in ''|*[!0-9]*|0|1) echo "[fatal] --racers must be an integer >= 2 (got '$RACERS')" >&2; exit 2 ;; esac
case "$STAGGER_MS" in ''|*[!0-9]*) echo "[fatal] --stagger-ms must be a non-negative integer (got '$STAGGER_MS')" >&2; exit 2 ;; esac

T="${TMPDIR:-/tmp}/claim-exclusion.$$"
rm -rf "$T" 2>/dev/null
mkdir -p "$T" || { echo "❌ could not create $T"; exit 2; }

if [ "$ORIGIN_MODE" = "live" ]; then
  REPO_ROOT="$(cd "$HERE/../.." && pwd)"
  ORIGIN_URL="$(git -C "$REPO_ROOT" remote get-url origin 2>/dev/null)"
  [ -n "$ORIGIN_URL" ] || { echo "❌ $REPO_ROOT has no origin remote — use --origin fake"; exit 2; }
else
  ORIGIN_URL="$T/origin.git"
  git init -q --bare "$ORIGIN_URL" || { echo "❌ could not create a bare origin"; exit 2; }
fi

# ⛔ A $$-SCOPED CLAIM NAMESPACE IN BOTH MODES. In `live` mode it is what keeps this run out of the
# production `refs/claims/*` namespace the fleet is using; in `fake` mode it costs nothing and keeps
# the two modes' code paths identical.
CLAIM_NS="refs/claims-excl-$$"; export CLAIM_NS
CLAIM_CACHE_NS="refs/claims-excl-cache-$$"; export CLAIM_CACHE_NS
CLAIM_TMP_NS="refs/claims-excl-tmp-$$"; export CLAIM_TMP_NS

# ── the boxes ─────────────────────────────────────────────────────────────────────────────────
# One repo per racer. They are independent working trees sharing ONE origin, which is what makes the
# race a race: the CAS is the ref update on the shared remote, not anything local.
i=1
while [ "$i" -le "$RACERS" ]; do
  b="$T/box$i"; mkdir -p "$b"
  git -C "$b" init -q || { echo "❌ git init failed in $b"; exit 2; }
  git -C "$b" remote add origin "$ORIGIN_URL"
  i=$((i + 1))
done
EMPTY_TREE=4b825dc642cb6eb9a060e54bf8d69288fbee4904

cleanup() {
  trap - EXIT INT TERM
  # ⛔ `live` mode must not leak refs onto the real origin, on ANY exit (the #1850 lesson: a Ctrl-C
  # between sections left orphaned refs behind, because the trap only cleaned local dirs).
  if [ "$ORIGIN_MODE" = "live" ]; then
    local ref sha
    while read -r sha ref; do
      [ -n "${ref:-}" ] || continue
      git -C "$T/box1" push -q --force-with-lease="$ref:$sha" origin ":$ref" 2>/dev/null
    done < <(git -C "$T/box1" ls-remote origin "$CLAIM_NS/*" 2>/dev/null)
    # The M5 probe branch, fenced on whatever it holds now. A branch is visible to the whole fleet,
    # so leaving one behind is a worse leak than a claim ref.
    sha="$(git -C "$T/box1" ls-remote origin "${BR:-}" 2>/dev/null | awk '{print $1}')"
    [ -n "${sha:-}" ] && git -C "$T/box1" push -q --force-with-lease="${BR}:${sha}" origin ":${BR}" 2>/dev/null
  fi
  rm -rf "$T" 2>/dev/null
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

if ! mkfifo "$T/.fifo-probe" 2>/dev/null; then
  echo "❌ this environment cannot create a FIFO, so the release barrier — and therefore the race — cannot be built"
  exit 2
fi
rm -f "$T/.fifo-probe"

echo "=== claim-exclusion: the measurement behind agent-infra#1908 ==="
echo "  origin=$ORIGIN_MODE  laps=$LAPS  racers=$RACERS  stagger=${STAGGER_MS}ms  namespace=$CLAIM_NS"

# ── race() — release $RACERS processes at a barrier, collect their outcomes ──────────────────
# Prints one line per racer. Sets R_WIN / R_LOST / R_INFRA / R_ODD and R_LINES (for prose asserts).
R_WIN=0; R_LOST=0; R_INFRA=0; R_ODD=0; R_LINES=""
race() { # race <op> [op-args...]
  local d="$T/race" i line rc res
  rm -rf "$d"; mkdir -p "$d"
  i=1
  while [ "$i" -le "$RACERS" ]; do
    mkfifo "$d/go.$i"
    CLAIM_EXCLUSION_AS_RACER=1 CLAIMS_SH="$CLAIMS_SH" \
      CLAIM_EXCLUSION_STAGGER="$(awk -v ms=$(( (i - 1) * STAGGER_MS )) 'BEGIN{printf "%.3f", ms / 1000}')" \
      bash "$SELF" "$T/box$i" "box$i" "$d/go.$i" "$d/out.$i" "$@" >/dev/null 2>&1 &
    i=$((i + 1))
  done
  # Every racer is now blocked in `read` on its own FIFO. Opening them for writing IS the release;
  # the writers go in the background so one slow racer cannot serialise the others behind it.
  i=1
  while [ "$i" -le "$RACERS" ]; do printf 'go\n' > "$d/go.$i" & i=$((i + 1)); done
  wait
  R_WIN=0; R_LOST=0; R_INFRA=0; R_ODD=0; R_LINES=""
  i=1
  while [ "$i" -le "$RACERS" ]; do
    line="$(cat "$d/out.$i" 2>/dev/null)"
    # A racer that wrote nothing never reached the acquire. That is a HARNESS failure, and it must
    # never be counted as a lost race — a silent racer counted as a loser would make
    # "exactly one winner" true while nothing was measured.
    [ -n "$line" ] || line=$'90\t<the racer wrote nothing — it never reached the acquire>\t'
    rc="${line%%$'\t'*}"; line="${line#*$'\t'}"
    res="${line%%$'\t'*}"
    printf '    box%s rc=%s :: %s\n' "$i" "$rc" "$res"
    R_LINES="$R_LINES box$i:rc=$rc:$res"
    case "$rc" in
      0) R_WIN=$((R_WIN + 1)) ;;
      1) R_LOST=$((R_LOST + 1)) ;;
      2) R_INFRA=$((R_INFRA + 1)) ;;
      *) R_ODD=$((R_ODD + 1)) ;;
    esac
    i=$((i + 1))
  done
}

# ── one() — a single holder, for the SEQUENTIAL probes (M3). Not a race, by design. ──────────
# Returns its rc in ONE_RC / text in ONE_RES.
ONE_RC=""; ONE_RES=""; ONE_COMMIT=""
one() { # one <box-index> <op> [op-args...]
  local idx="$1" fifo="$T/one.$1.fifo" out="$T/one.$1.out" line
  rm -f "$fifo" "$out"; mkfifo "$fifo"
  CLAIM_EXCLUSION_AS_RACER=1 CLAIMS_SH="$CLAIMS_SH" \
    bash "$SELF" "$T/box$idx" "box$idx" "$fifo" "$out" "$2" "${@:3}" >/dev/null 2>&1 &
  printf 'go\n' > "$fifo"
  wait
  line="$(cat "$out" 2>/dev/null)"
  [ -n "$line" ] || line=$'90\t<the probe wrote nothing>\t'
  ONE_RC="${line%%$'\t'*}"; line="${line#*$'\t'}"
  ONE_RES="${line%%$'\t'*}"; ONE_COMMIT="${line##*$'\t'}"
}

# `exclusive <label> <laps-exclusive> <win-max>` — the shared verdict for a CAS row that must hold.
exclusive() {
  local label="$1" laps_ok="$2" win_max="$3"
  if [ "$win_max" -eq 1 ] && [ "$laps_ok" -eq "$LAPS" ]; then
    ok "$label: EXCLUDES — $LAPS/$LAPS laps had exactly one winner, max winners per lap $win_max"
  elif [ "$win_max" -gt 1 ]; then
    bad "$label: DOES NOT EXCLUDE — $win_max winners in one lap"
  else
    bad "$label: INCONCLUSIVE — $laps_ok/$LAPS laps had exactly one winner (max $win_max); a zero-winner or odd-exit lap is not exclusion"
  fi
  [ "$R_ODD" -eq 0 ] && ok "$label: every racer reached the acquire (no silent process)" \
    || bad "$label: $R_ODD racer(s) produced no outcome — the run is not a measurement"
  # ⛔ The vacuity guard: `rc=1` must mean "another box won", never "the registry was unreadable".
  # An infra exit counted as a loss would make EXACTLY-ONE always true while nothing was excluded.
  [ "$R_INFRA" -eq 0 ] && ok "$label: no racer exited 2 (infra) — a loss here is a real lost race" \
    || bad "$label: $R_INFRA racer(s) exited 2 (infra) — indistinguishable from a loss, so this lap proves nothing"
}

# ── M1: dispatch — N processes, ONE issue, same lease window ────────────────────────────────
echo
echo "── M1: dispatch class — claim_issue_acquire, $RACERS racers x $LAPS laps ──────────────"
M1_WIN_MAX=0; M1_LAPS_EXCLUSIVE=0; M1_LAST=""
n=990000
lap=1
while [ "$lap" -le "$LAPS" ]; do
  n=$((n + 1))
  echo "  lap $lap (issue-$n):"
  race issue "$n" 600
  M1_LAST="$R_LINES"
  [ "$R_WIN" -gt "$M1_WIN_MAX" ] && M1_WIN_MAX=$R_WIN
  [ "$R_WIN" -eq 1 ] && [ "$R_INFRA" -eq 0 ] && [ "$R_ODD" -eq 0 ] && M1_LAPS_EXCLUSIVE=$((M1_LAPS_EXCLUSIVE + 1))
  lap=$((lap + 1))
done
exclusive "M1 dispatch" "$M1_LAPS_EXCLUSIVE" "$M1_WIN_MAX"
ck "M1 dispatch: the loser is told WHO holds it (the loser log line #1908 asks to record)" "held by" "$M1_LAST"

# ── M2: review / evidence — N processes, ONE PR head, same lease window ─────────────────────
echo
echo "── M2: review class — claim_acquire, $RACERS racers x $LAPS laps ──────────────────────"
H1=0123456789abcdef0123456789abcdef01234567
M2_WIN_MAX=0; M2_LAPS_EXCLUSIVE=0
p=880000
lap=1
while [ "$lap" -le "$LAPS" ]; do
  p=$((p + 1))
  echo "  lap $lap (pr-$p head ${H1:0:12}):"
  race pr "$p" "$H1" 600
  [ "$R_WIN" -gt "$M2_WIN_MAX" ] && M2_WIN_MAX=$R_WIN
  [ "$R_WIN" -eq 1 ] && [ "$R_INFRA" -eq 0 ] && [ "$R_ODD" -eq 0 ] && M2_LAPS_EXCLUSIVE=$((M2_LAPS_EXCLUSIVE + 1))
  lap=$((lap + 1))
done
exclusive "M2 review" "$M2_LAPS_EXCLUSIVE" "$M2_WIN_MAX"

# ── M3: landing — the SAME PR at TWO DIFFERENT heads ────────────────────────────────────────
# ⛔ THIS IS THE ROW #1908 EXISTS FOR. The claim key is `<PR>-<sha12>`, content-addressed on the
# HEAD. Two boxes looking at the same PR at two heads mint two DISTINCT keys, so the CAS each wins
# is not the same CAS — the claim expresses "this head", never "this PR". Measured, not assumed.
echo
echo "── M3: landing class — ONE PR, TWO heads (the per-PR gap) ────────────────────────────────"
H2=fedcba9876543210fedcba9876543210fedcba98
P3=770001
one 1 pr "$P3" "$H1" 600
echo "  holder at head ${H1:0:12}: rc=$ONE_RC :: $ONE_RES"
M3_FIRST_RC="$ONE_RC"
# The second holder arrives at a DIFFERENT head of the SAME PR, with the first claim LIVE.
one 2 pr "$P3" "$H2" 600
echo "  second holder at head ${H2:0:12} (same PR #$P3): rc=$ONE_RC :: $ONE_RES"
if [ "$M3_FIRST_RC" = "0" ] && [ "$ONE_RC" = "0" ]; then
  ok "M3 landing: MEASURED GAP — two DIFFERENT heads of ONE PR both acquire; the claim is per-head, never per-PR"
elif [ "$M3_FIRST_RC" = "0" ] && [ "$ONE_RC" = "1" ]; then
  bad "M3 landing: the documented per-PR gap is NOT reproduced (the second head was refused) — a per-PR exclusion now exists; update README §7.2d and retire the landing row"
else
  bad "M3 landing: inconclusive (head-1 rc=$M3_FIRST_RC, head-2 rc=$ONE_RC) — this row proves nothing"
fi
# Release both, so M4/M5 start from a known state.
for h in "$H1" "$H2"; do
  r="$CLAIM_NS/$P3-${h:0:12}"
  cur="$(git -C "$T/box1" ls-remote origin "$r" 2>/dev/null | awk '{print $1}')"
  [ -n "$cur" ] && git -C "$T/box1" push -q --force-with-lease="$r:$cur" origin ":$r" 2>/dev/null
done

# ── M4: fencing — can the LOSER delete the winner's claim? ──────────────────────────────────
echo
echo "── M4: fencing — the loser tries to release the winner's claim ───────────────────────────"
P4=660002
race pr "$P4" "$H1" 600
CREF="$CLAIM_NS/$P4-${H1:0:12}"
CUR="$(git -C "$T/box1" ls-remote origin "$CREF" 2>/dev/null | awk '{print $1}')"
# The LOSER's own commit: it pushed nothing, so mint one the way claims.sh does.
LOSE_COMMIT="$( cd "$T/box2" || exit 1
                CLAIM_REPO="$T/box2"; CLAIM_OWNER_HOST=box2; export CLAIM_REPO CLAIM_OWNER_HOST
                . "$CLAIMS_SH"
                _claim_commit box2 "$(( $(date +%s) + 600 ))" )"
out_rel="$( cd "$T/box2" || exit 1
            CLAIM_REPO="$T/box2"; CLAIM_OWNER_HOST=box2; export CLAIM_REPO CLAIM_OWNER_HOST
            . "$CLAIMS_SH"
            claim_release "$T/box2" "$P4" "$H1" "$LOSE_COMMIT" )"
rc_rel=$?
after="$(git -C "$T/box2" ls-remote origin "$CREF" 2>/dev/null | awk '{print $1}')"
echo "  loser's fenced release rc=$rc_rel :: $out_rel"
echo "  claim ref: before=${CUR:-<none>} after=${after:-<none>}"
[ "$rc_rel" -ne 0 ] && ok "M4 fencing: the loser's release is REFUSED (rc=$rc_rel)" \
  || bad "M4 fencing: the loser's release was ACCEPTED — a non-holder can delete the holder's claim"
[ -n "$CUR" ] && [ "$after" = "$CUR" ] && ok "M4 fencing: the winner's claim ref is UNCHANGED by the loser" \
  || bad "M4 fencing: the claim ref changed under the loser's release (${CUR:-<none>} -> ${after:-<none>})"
[ -n "$CUR" ] && git -C "$T/box1" push -q --force-with-lease="$CREF:$CUR" origin ":$CREF" 2>/dev/null

# ── M5: the fence any lander-side exclusion would rest on — a MOVED branch ref ──────────────
# The merge path does not push the claim's ref to land; it asks GitHub to merge the PR. So this
# measures the FENCE's own behaviour (the mechanism `--force-with-lease` provides), NOT a merge.
# §2 below is the sharp one: B's commit is a DESCENDANT of A's landing, so a plain push would be a
# legal fast-forward — the refusal can only come from the lease, never from non-fast-forward.
echo
echo "── M5: stale writer — a MOVED branch ref, leased and plain pushes ────────────────────────"
# ⛔ THE PROBE BRANCH IS $$-SCOPED, AND DELETED BY THE TRAP IN `live` MODE. A fixed name pushed to the
# real origin creates a branch in the repository every peer sees — the first version of this file
# left `refs/heads/land-probe` there, which is exactly the kind of side effect a MEASUREMENT must not
# have. Scoping it also stops two concurrent runs from moving each other's base and reading their
# own ref-lock collisions as fence behaviour.
BR="refs/heads/land-excl-$$-probe"
# ⛔ commit-tree takes a TREE and `-p` for a PARENT. Passing the parent as the tree argument is the
# mistake this block made first: `commit-tree <sha-of-a-commit>` fails with "is not a valid 'tree'
# object", every later sha comes back EMPTY, and an empty sha in `"$c:refs/heads/x"` is a DELETE
# refspec — measured: it reported rc=0 with "deleting a non-existent ref", so the "plain push is
# refused" assertion below would have been satisfied by a push that pushed NOTHING.
G() { git -c user.name=fleet-test -c user.email=test@localhost "$@"; }
# ⛔ AND EACH BOX IS AN INDEPENDENT OBJECT STORE: B mints its candidates only AFTER fetching what A
# landed, never minted-in-A-and-pushed-from-B (which fails the same way).
C1="$(G -C "$T/box1" commit-tree "$EMPTY_TREE" -m base)"
C2="$(G -C "$T/box1" commit-tree "$EMPTY_TREE" -p "$C1" -m landed-by-A)"
[ -n "$C1" ] && [ -n "$C2" ] && G -C "$T/box1" push -q origin "$C1:$BR" 2>/dev/null
BASE="$(git -C "$T/box1" ls-remote origin "$BR" 2>/dev/null | awk '{print $1}')"
echo "  base ref  : ${BASE:-<none>}"
[ -n "$C2" ] && G -C "$T/box1" push -q origin "$C2:$BR" 2>/dev/null     # A lands
NOW="$(git -C "$T/box1" ls-remote origin "$BR" 2>/dev/null | awk '{print $1}')"
echo "  after A   : ${NOW:-<none>}"
G -C "$T/box2" fetch -q origin "+$BR:refs/remotes/m5-a" 2>/dev/null
C3=""; C2B=""
if [ -n "$C1" ] && [ -n "$C2" ]; then
  C3="$(G -C "$T/box2" commit-tree "$EMPTY_TREE" -p "$C1" -m landed-by-B)"
  C2B="$(G -C "$T/box2" commit-tree "$EMPTY_TREE" -p "$C2" -m rebuilt-on-A-by-B)"
fi
if [ -n "$C1" ] && [ -n "$C2" ] && [ -n "$C3" ] && [ -n "$C2B" ] \
   && [ -n "$BASE" ] && [ -n "$NOW" ] && [ "$NOW" != "$BASE" ]; then
  ok "M5 setup: the branch MOVED between B's read and B's write (${BASE:0:12} -> ${NOW:0:12})"
  # (1) FAST-FORWARDABLE, but leased on the STALE base: only the lease can refuse it.
  leased_rc=0
  out_leased="$(G -C "$T/box2" push -q --force-with-lease="$BR:$BASE" origin "$C2B:$BR" 2>&1)" || leased_rc=$?
  still="$(git -C "$T/box1" ls-remote origin "$BR" 2>/dev/null | awk '{print $1}')"
  echo "  B leased push (ff-able) rc=$leased_rc :: $(printf '%s' "$out_leased" | tr '\n' ' ' | cut -c1-140)"
  [ "$leased_rc" -ne 0 ] && ok "M5 fence: a FAST-FORWARDABLE push leased on a stale base is REFUSED (rc=$leased_rc) — the lease, not non-fast-forward, refused it" \
    || bad "M5 fence: a leased push on a stale base LANDED — the fence does not hold"
  [ "$still" = "$NOW" ] && ok "M5 fence: the ref still points at A's landing — B could not move it" \
    || bad "M5 fence: the ref moved to ${still:-<none>} — B overwrote A's landing"
  # (2) A plain push from the stale base: NOT a fast-forward, so the receive-pack refuses it.
  plain_rc=0
  out_plain="$(G -C "$T/box2" push -q origin "$C3:$BR" 2>&1)" || plain_rc=$?
  still2="$(git -C "$T/box1" ls-remote origin "$BR" 2>/dev/null | awk '{print $1}')"
  echo "  B plain push rc=$plain_rc :: $(printf '%s' "$out_plain" | tr '\n' ' ' | cut -c1-140)"
  [ "$plain_rc" -ne 0 ] && ok "M5 fence: a PLAIN push from the stale base is REFUSED (non-fast-forward)" \
    || bad "M5 fence: a plain push from the stale base LANDED — a lander could rewrite a moved head"
  [ "$still2" = "$NOW" ] && ok "M5 fence: the ref is unchanged by the plain push too" \
    || bad "M5 fence: the ref moved to ${still2:-<none>} on the plain push"
else
  bad "M5 setup: could not build the probe (C1='${C1:-}' C2='${C2:-}' C3='${C3:-}' C2B='${C2B:-}' base='${BASE:-}' now='${NOW:-}') — the two fence probes below were SKIPPED, not passed"
fi

# ── the table this file exists to produce ───────────────────────────────────────────────────
# README §7.2d is copied from HERE. Keep the columns identical to the doc's.
cat <<EOF

── measured table (the numbers above; README §7.2d quotes this) ──────────────────────────
| operation | claim key | duplicate behaviour MEASURED | tolerant of at-least-once? |
|---|---|---|---|
| dispatch | issue-<N> | ${M1_LAPS_EXCLUSIVE}/${LAPS} laps: exactly one winner of ${RACERS}; loser refused and names the holder | yes (idempotent side effects) |
| review / evidence | <PR>-<sha12> | ${M2_LAPS_EXCLUSIVE}/${LAPS} laps: exactly one winner of ${RACERS}; loser refused | yes (a duplicate comment) |
| landing: same head | <PR>-<sha12> | the same CAS as review — the second worker exits BEFORE review or merge | only for that head |
| landing: PR moved to a new head | <PR>-<sha12>, a DIFFERENT key | M3: both acquire — the claim cannot express "this PR" | NO |
| fence (release / stale write) | the ref's VALUE | M4 loser's release refused; M5 leased stale push refused | n/a (a fence, not a claim) |
EOF

echo
echo "================ RESULT: $PASS passed, $FAIL failed ================"
[ "$FAIL" -eq 0 ]
