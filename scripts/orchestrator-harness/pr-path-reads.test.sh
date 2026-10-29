#!/bin/bash
# pr-path-reads.test.sh — agent-infra#2601: the PR path must have a READ before it can act.
#
# ⛔ THE DEFECT THIS SUITE PINS. The agent-infra controller ran 549 cycles, listed 72 open PRs
# correctly (`[select] population=open-rows scan=ok (open-rows=72 …)`), and spawned NOTHING — every
# cycle, 100% of them:
#
#   [pr] PR path: NO UNIT SPAWNED this cycle — 72 row(s) with a named reason
#        (most common: 72 no per-PR read this cycle (the open-PR listing was unchanged — 304 …))
#
# Two facts made that permanent rather than transient:
#   1. `SWEEP_LIST` — the ONLY actable row set (`pr \t branch \t draft`, which is what the arms need
#      and what `state/pr-meta.tsv` does NOT carry) — lived in PROCESS MEMORY and was filled only on
#      a 200. The box runs one cycle per process (measured: 605 `[startup]` lines against 555 cycle
#      banners), so a 304 cycle had no memory to inherit and no rows to act on. Measured: 152 of 221
#      `[select]` lines were such cycles.
#   2. A full sweep costs >= 2 `gh pr view` calls per PR. At 70 rows that is minutes, while the
#      controller is relaunched roughly every 12-45s — so the cycles that DID have rows never reached
#      the arms at the end of the loop. Measured: 0 `act` rows and 0 `[pr] … acted` lines in 555
#      cycles; `state/prclass.tsv` held ONE row.
# A 304 is GitHub asserting "identical to what you cached", so the cached rows ARE that cycle's read:
# the fix performs the read instead of dropping the requirement. The bounded rotating window makes a
# pass COMPLETE, so the arms are actually reached.
#
# HOW THESE CHECKS ARE WRITTEN: the shipped blocks are extracted VERBATIM by their markers and driven
# against a stub `gh`, in a SEPARATE SUBSHELL PER CYCLE (that is the real runtime — one process per
# cycle — and it is the whole reason memory-only state was fatal). No network, no tmux, no gh.
#
# Run:  bash scripts/orchestrator-harness/pr-path-reads.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$HERE/orch-loop.sh"
PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/pr-path-reads.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> PR-path read contract ($HERE)"

[ -f "$LOOP" ] || { echo "  ❌ missing $LOOP"; exit 1; }
need() { if [ -s "$1" ]; then return 0; else bad "could not extract $2 from $LOOP"; return 1; fi; }

awk '/^  # BEGIN sweep-listing/,/^  # END sweep-listing/' "$LOOP" > "$T/block.sh"
sed -n '/# \[sweep-window:begin\]/,/# \[sweep-window:end\]/p' "$LOOP" | sed '1d;$d' > "$T/window.sh"
sed -n '/# \[prdisp-apply:begin\]/,/# \[prdisp-apply:end\]/p' "$LOOP" | sed '1d;$d' > "$T/apply.sh"
sed -n '/# \[sweep-cursor:begin\]/,/# \[sweep-cursor:end\]/p' "$LOOP" | sed '1d;$d' > "$T/cursor.sh"
# The shipped helpers the blocks call, taken rather than copied so the two cannot drift.
grep -m1 '^is_num() {' "$LOOP"   > "$T/deps.sh"
grep -m1 '^is_limit() {' "$LOOP" >> "$T/deps.sh"
awk '/^# BEGIN sweep-quota/,/^# END sweep-quota/' "$LOOP" >> "$T/deps.sh"
# The loop's own row reader, so "the rows are consumable" is graded on the shipped read, not a copy.
grep -E 'read -r PR BR DRAFT OWN' "$LOOP" | head -1 | sed -E 's/^ *//' > "$T/reader.sh"

# ── stub gh ─────────────────────────────────────────────────────────────────────────────────────
# 200 prints three REST rows (the block's own awk reshapes them into `pr \t branch \t draft`),
# 304 is the conditional answer, `netfail` is an unreadable listing.
GHMODE=200
mk_gh() {
  mkdir -p "$1/bin"
  cat > "$1/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
case "${GHMODE:-200}" in
  200) printf 'HTTP/2.0 200 OK\r\nEtag: W/"t9"\r\nX-Ratelimit-Remaining: 4990\r\n\r\n'
       printf '7001\tfix/aaa\tfalse\n7002\tfix/bbb\tfalse\n7003\tdocs/ccc\tfalse\n'
       exit 0 ;;
  304) printf 'HTTP/2.0 304 Not Modified\r\nEtag: "t9"\r\n\r\n'
       printf 'unexpected end of JSON input\n' >&2
       exit 1 ;;
  *)   printf 'Post "https://api.github.com/graphql": net/http: TLS handshake timeout\n' >&2
       exit 1 ;;
esac
SH
  chmod +x "$1/bin/gh"
}

# A $O with a state dir; `mk_case <name>` starts a fresh box.
O=""
mk_case() { D="$T/$1"; mkdir -p "$D/o/state"; mk_gh "$D"; : > "$D/calls"; O="$D/o"; }

# cycle — ONE process, exactly like the controller. Runs the shipped listing block and echoes the
# actable set it produced. Nothing in memory crosses between calls to this function.
LIST=""; LOGOUT=""; NOTEOUT=""
cycle() {
  local d="$1"
  : > "$d/calls"
  LOGOUT="$( cd "$d" && \
    PATH="$d/bin:/usr/bin:/bin" O="$d/o" LOG="$d/log" OR="acme/widget" \
    SEL='select(.headRefName|test("."))' SWEEP_MAX_AGE=600 SWEEP_MIN_REMAIN=20 GHMODE="$GHMODE" \
    GH_CALLS="$d/calls" \
    bash -uc '. "$1" || exit 90; . "$2" || exit 91; printf "L<<BEGIN\n%s\nL<<END\nN<<BEGIN\n%s\nN<<END\n" "${SWEEP_LIST:-}" "${SWEEP_CACHE_NOTE:-}"' \
      _ "$T/deps.sh" "$T/block.sh" 2>&1 )"
  # Delimited + awk, not an inline sentinel: SWEEP_LIST is MULTI-LINE (one row per PR), so a
  # single-line capture silently keeps the first row and reads as "the cache held one row".
  LIST="$(printf '%s\n' "$LOGOUT" | awk '/^L<<BEGIN$/{f=1;next} /^L<<END$/{f=0} f')"
  NOTEOUT="$(printf '%s\n' "$LOGOUT" | awk '/^N<<BEGIN$/{f=1;next} /^N<<END$/{f=0} f')"
}
ROWS3="$(printf '7001\tfix/aaa\tfalse\n7002\tfix/bbb\tfalse\n7003\tdocs/ccc\tfalse')"

# ── 1) the read survives the process; a 304 cycle is not blind ──────────────────────────────────
if need "$T/block.sh" "the sweep-listing block"; then
  GHMODE=200; mk_case survive
  cycle "$D"
  [ "$LIST" = "$ROWS3" ] && ok "200: the actable rows are produced" \
                         || bad "200 produced LIST='$LIST'"
  [ -s "$O/state/sweep-rows.tsv" ] && ok "200: the actable rows are PERSISTED (state/sweep-rows.tsv)" \
                                   || bad "200 did not persist state/sweep-rows.tsv"

  # ⛔ A NEW PROCESS. This is the runtime: nothing survives but files.
  GHMODE=304
  cycle "$D"
  [ "$LIST" = "$ROWS3" ] \
    && ok "304 in a fresh process: the actable rows are RESTORED from the cache (the PR path can act)" \
    || bad "304 in a fresh process yielded LIST='$LIST' — the PR path is blind for this cycle"
  grep -q 'restored 3 actable row(s)' "$D/log" 2>/dev/null \
    && ok "304: the restore is logged with its row count and cache age" \
    || bad "304: no restore line — log is '$(cat "$D/log" 2>/dev/null)'"

  # ── 2) a 304 with no cache REFUSES LOUDLY AND NAMES THE ARTEFACT ──────────────────────────────
  rm -f "$O/state/sweep-rows.tsv"
  cycle "$D"
  [ -z "$LIST" ] && ok "304 without a cache: no rows are invented" \
                 || bad "304 without a cache produced '$LIST'"
  case "$NOTEOUT" in
    *sweep-rows.tsv*) ok "304 without a cache: the refusal NAMES state/sweep-rows.tsv" ;;
    *) bad "304 without a cache: the reason does not name the missing artefact ('$NOTEOUT')" ;;
  esac
  grep -q '304 with NO CACHE' "$D/log" 2>/dev/null \
    && ok "304 without a cache: a ⛔ line says the cell cannot merge, not that it is idle" \
    || bad "304 without a cache: no loud line — log is '$(cat "$D/log" 2>/dev/null)'"

  # ── 3) an UNREADABLE listing is never papered over with the cache, and is never silent ────────
  printf '7001\tfix/aaa\tfalse\n' > "$O/state/sweep-rows.tsv"
  GHMODE=netfail
  cycle "$D"
  [ -z "$LIST" ] && ok "listing FAILED: the cache is NOT served (no act on an unconfirmed read)" \
                 || bad "listing FAILED: rows were served from the cache ('$LIST')"
  grep -q 'PR listing FAILED (network' "$D/log" 2>/dev/null \
    && ok "listing FAILED: logged loudly and classified (never 'nothing to do')" \
    || bad "listing FAILED: log is '$(cat "$D/log" 2>/dev/null)'"
  case "$NOTEOUT" in
    *FAILED*) ok "listing FAILED: the per-PR reason carries the failure, not the generic 304 string" ;;
    *) bad "listing FAILED: the per-PR reason is '$NOTEOUT'" ;;
  esac
fi

# ── 4) the restored rows are consumable by the loop's OWN reader ────────────────────────────────
# The arms sit behind `read -r PR BR DRAFT OWN`. If the restored shape were wrong, the loop would
# read garbage silently — so it is graded with the shipped `read`, not a re-implementation.
# ⛔ THE LIST UNDER TEST IS THE RESTORED ONE, NOT A LITERAL (review P2): an earlier version piped a
# test-owned constant through a test-owned `read`, so it passed on the pre-fix tree — an assertion
# about nothing. This runs the SHIPPED reader over the rows the 304 above actually restored.
if [ -s "$T/reader.sh" ] && [ -n "${LIST:-}" ]; then
  got="$(printf '%s\n' "$LIST" | ( IFS="$(printf '\t')"; while read -r PR BR DRAFT OWN; do
            printf '%s|%s|%s\n' "${PR:-}" "${BR:-}" "${DRAFT:-}"; done ) | head -1)"
  [ "$got" = "7001|fix/aaa|false" ] \
    && ok "the restored TSV is read by the shipped \`read -r PR BR DRAFT OWN\` as pr/branch/draft" \
    || bad "the shipped reader produced '$got' from the restored rows"
fi

# ── 5) the per-cycle window: bounded work, and every row is still visited ───────────────────────
# ⛔ WITHOUT THIS THE FIX DOES NOT REACH THE ARMS: a 70-row pass does not fit in one controller
# lifetime (measured 12-45s per launch), so the loop is torn down before the acting case.
# ⛔ AND THE WINDOW ALONE IS NOT THE CONTRACT (review P1). The cursor must advance by the rows that
# were ACTUALLY READ, after the pass — not by K up front. Advanced up front, a cycle torn down after
# M of K rows stepped over the tail of every window, and the start positions then live in one residue
# class mod gcd(K,N), so a whole class of PRs was never read (`K=8, N=70, M=1` → 35 of 70, ever).
if need "$T/window.sh" "the per-cycle sweep window" && need "$T/cursor.sh" "the post-pass cursor advance"; then
  mk_case window
  # 20 rows, K=8 -> ceil(20/8) = 3 cycles must visit all 20, with no row skipped and none twice.
  SEL_ROWS="$(i=1; while [ "$i" -le 20 ]; do printf '90%02d\tfix/w%02d\tfalse\tUNOWNED\n' "$i" "$i"; i=$((i+1)); done)"
  K=8; SEL_N=20; SWEEP_ROWS_PER_CYCLE=$K
  : > "$O/state/sweep-cursor"

  # pass <rows-read-of-the-window> — the window, then the pass, then the CURSOR ADVANCE.
  # `rows-read` models how much of the window a (possibly killed) cycle actually disposed of. The
  # window and the cursor are separate processes here only because each is driven on its own; in the
  # loop they share one process, and the state file is what carries the start row between them.
  W=""
  pass() {
    local readn="$1"
    # 1) the window (writes the START row to state/sweep-cursor, which is what a resume needs)
    W="$( cd "$D" && O="$D/o" LOG="$D/winlog" SEL_ROWS="$SEL_ROWS" \
      SWEEP_ROWS_PER_CYCLE="$K" bash -uc '. "$1"; . "$2"; printf "%s\n" "$SWEEP_WINDOW_PR"' \
        _ "$T/deps.sh" "$T/window.sh" )"
    # 2) the pass: `readn` of the window's rows produce a disposition. `$W` is the space-separated
    # id list the window block echoes; the loop's own window is multi-line TSV, so it is rebuilt in
    # that shape for the cursor drive below.
    printf '%s\n' $W | awk '{print $1"\t-\t-\tUNOWNED"}' > "$D/selwindow.tsv"
    : > "$D/disp.tsv"
    if [ "$readn" -gt 0 ]; then
      printf '%s\n' $W | awk -v n="$readn" 'NR<=n && NF {print $1"\t-\t-\tact\tstub"}' >> "$D/disp.tsv"
    fi
    # 3) the cursor advance (reads the start row back from state)
    ( cd "$D" && O="$D/o" LOG="$D/winlog" PRDISP="$D/disp.tsv" SEL_ROWS="$SEL_ROWS" \
        SEL_WINDOW="$(cat "$D/selwindow.tsv")" SWEEP_ROWS_PER_CYCLE="$K" SEL_N="$SEL_N" \
        bash -uc '. "$1"; . "$2"' _ "$T/deps.sh" "$T/cursor.sh" ) >> "$D/winlog" 2>&1
    w="$W"
  }

  seen=""; n=1
  while [ "$n" -le 3 ]; do
    pass 8
    [ "$(printf '%s\n' "$w" | wc -w | tr -d ' ')" = "8" ] \
      && ok "cycle $n: the window holds exactly K=8 rows (bounded work)" \
      || bad "cycle $n: window held $(printf '%s\n' "$w" | wc -w | tr -d ' ') row(s), want 8"
    seen="$seen $w"
    n=$((n+1))
  done
  uniq_seen="$(printf '%s\n' $seen | sort -u | wc -l | tr -d ' ')"
  [ "$uniq_seen" = "20" ] \
    && ok "3 cycles x K=8 visited all 20 rows (none skipped, none stranded)" \
    || bad "3 cycles visited $uniq_seen distinct rows of 20 — the rotation strands work"
  [ "$(cat "$O/state/sweep-cursor" 2>/dev/null)" = "4" ] \
    && ok "the cursor advanced by the rows READ (8*3=24 mod 20 = 4) — the window RESUMES" \
    || bad "the cursor is '$(cat "$O/state/sweep-cursor" 2>/dev/null)' (want 4)"

  # ⛔ THE P1 CASE: a cycle torn down after ONE row must resume at row 2, not at row 9.
  printf '0\n' > "$O/state/sweep-cursor"; : > "$D/winlog"
  pass 1
  first_row="$(printf '%s\n' "$w" | awk '{print $1}')"
  cursor_after="$(cat "$O/state/sweep-cursor" 2>/dev/null)"
  [ "$cursor_after" = "1" ] \
    && ok "a pass that read ONE of K rows advances the cursor by ONE (resumes at row 2, not row 9)" \
    || bad "after reading 1 of 8 rows the cursor is '$cursor_after' (want 1 — advancing by K would skip 7)"
  grep -q 'cursor:' "$D/winlog" 2>/dev/null \
    && ok "the cursor advance says how much of the window was actually read" \
    || bad "no cursor line in '$(cat "$D/winlog" 2>/dev/null)'"

  # A pass that read NOTHING repeats the same window: a cycle that read nothing must skip nothing.
  printf '0\n' > "$O/state/sweep-cursor"; : > "$D/winlog"
  pass 0
  [ "$(cat "$O/state/sweep-cursor" 2>/dev/null)" = "0" ] \
    && ok "a pass that read NOTHING leaves the cursor alone (the same window is retried)" \
    || bad "a zero-row pass moved the cursor to '$(cat "$O/state/sweep-cursor" 2>/dev/null)'"
  grep -q 'the same window is retried' "$D/winlog" 2>/dev/null \
    && ok "…and says so, rather than silently rotating past the rows it never read" \
    || bad "a zero-row pass is not named in the log"

  # A wrapping window must not print a range that does not exist (review P2).
  printf '16\n' > "$O/state/sweep-cursor"; : > "$D/winlog"
  pass 8
  note="$(grep -o 'window=[^ ]*.*of 20[^)]*' "$D/winlog" 2>/dev/null | head -1)"
  case "$note" in
    *"then 1-4 of 20"*) ok "a WRAPPING window reports '17-20 then 1-4 of 20', never a row past the set" ;;
    *"17-24"*) bad "a wrapping window still reports a range past the set ('$note')" ;;
    *) bad "the wrapping window note is '$note'" ;;
  esac

  # ⛔ A NO-READ CYCLE MUST NOT INHERIT THE PREVIOUS CYCLE'S WINDOW (#2640 review, P1).
  # This block runs inside `while true`; on a deferral, a failed listing or a cache-less 304 `SEL_N`
  # is 0, the window is never recomputed — and an un-reset `SEL_WINDOW` would hand the sweep loop the
  # PREVIOUS cycle's rows, so the arms would fire on a listing this cycle never read. Both cycles are
  # driven in ONE shell here, because that is the only way the leak can show.
  leak="$( cd "$D" && O="$D/o" LOG="$D/leaklog" SWEEP_ROWS_PER_CYCLE="$K" \
      SEL_ROWS="$SEL_ROWS" bash -uc '. "$1"; . "$2"; printf "A=%s;" "${SEL_WINDOW:+set}"' _ "$T/deps.sh" "$T/window.sh" )"
  leak="$leak$( cd "$D" && O="$D/o" LOG="$D/leaklog" SWEEP_ROWS_PER_CYCLE="$K" \
      SEL_ROWS="" bash -uc '. "$1"; . "$2"; printf "B=%s" "${SEL_WINDOW:+set}"' _ "$T/deps.sh" "$T/window.sh" )"
  [ "$leak" = "A=set;B=" ] \
    && ok "a cycle that read NOTHING does not inherit the previous cycle's window (SEL_WINDOW is reset)" \
    || bad "the previous cycle's window leaked into a no-read cycle ('$leak') — the arms would fire on an unread listing"

  # A window that fits the whole set must not rotate: leaving a stale cursor would skip rows the
  # moment the backlog grew past K again.
  SEL_ROWS="$(printf '9001\tfix/a\tfalse\tUNOWNED\n9002\tfix/b\tfalse\tUNOWNED')"
  SEL_N=2; printf '0\n' > "$O/state/sweep-cursor"
  pass 2
  [ "$(printf '%s\n' "$w" | wc -w | tr -d ' ')" = "2" ] \
    && ok "a set smaller than K is swept WHOLE (no rotation, no waiting for the next cycle)" \
    || bad "a 2-row set produced window '$w'"
  [ "$(cat "$O/state/sweep-cursor" 2>/dev/null)" = "0" ] \
    && ok "a set smaller than K leaves the cursor at zero (no stale offset to skip on growth)" \
    || bad "the cursor moved to '$(cat "$O/state/sweep-cursor" 2>/dev/null)'"
fi

# ── 6) rows outside the window are NAMED, never dropped ────────────────────────────────────────
# The whole point of a bounded pass is that what it did not reach says so. A silent skip is the
# original defect with a new cause.
if need "$T/apply.sh" "the per-PR disposition block"; then
  mk_case apply
  printf '' > "$O/prdisp.tsv"
  OUT="$( cd "$D" && O="$D/o" PRDISP="$O/prdisp.tsv" PRDISP_OK=1 \
      OPEN_ROWS="7001:aaa:fix/aaa 7002:bbb:fix/bbb 7003:ccc:docs/ccc" \
      SWEEP_LIST="$(printf '7001\tfix/aaa\tfalse\n7002\tfix/bbb\tfalse')" \
      SWEEP_WINDOW_PR=" 7001 " SWEEP_WIN_NOTE="window=1-1 of 2 (K=1/cycle, rotating; SWEEP_ROWS_PER_CYCLE)" \
      SEL_N=2 SWEEP_ROWS_PER_CYCLE=1 SCOPE_MODE=own SWEEP_CACHE_NOTE="" \
      bash -uc 'pr_owned() { return 1; }; disp() { printf "%s\t%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$4" "$5" >> "$PRDISP"; }; . "$1"; . "$2"' \
        _ "$T/deps.sh" "$T/apply.sh" 2>&1 )"
  row7002="$(awk -F'\t' '$1=="7002"{print $5}' "$O/prdisp.tsv" 2>/dev/null)"
  case "$row7002" in
    *"outside this cycle's sweep window"*) ok "a row outside the window is NAMED with the window it missed" ;;
    *) bad "row 7002 (swept but outside the window) carries reason '$row7002'" ;;
  esac
  case "$row7002" in
    *"no per-PR read"*) bad "an out-of-window row still claims 'no per-PR read' (the defect, relabelled)" ;;
    *) ok "an out-of-window row does NOT claim 'no per-PR read' (it WAS read — just not this cycle)" ;;
  esac
  row7003="$(awk -F'\t' '$1=="7003"{print $5}' "$O/prdisp.tsv" 2>/dev/null)"
  case "$row7003" in
    *"not in this cycle's swept set"*) ok "a row outside the swept set keeps its own, different reason" ;;
    *) bad "row 7003 (never in SWEEP_LIST) carries reason '$row7003'" ;;
  esac

  # ── 7) NO actable set: the reason carries the CAUSE, not one string for three causes ─────────
  : > "$O/prdisp.tsv"
  ( cd "$D" && O="$D/o" PRDISP="$O/prdisp.tsv" PRDISP_OK=1 OPEN_ROWS="7001:aaa:fix/aaa" \
      SWEEP_LIST="" SWEEP_WINDOW_PR="" SEL_N=0 SWEEP_ROWS_PER_CYCLE=8 SCOPE_MODE=own \
      SWEEP_CACHE_NOTE="state/sweep-rows.tsv is missing/empty (a 304 vouches for a listing this box never cached)" \
      bash -uc 'pr_owned() { return 1; }; disp() { printf "%s\t%s\t%s\t%s\t%s\n" "$1" "$2" "$3" "$4" "$5" >> "$PRDISP"; }; . "$1"; . "$2"' \
        _ "$T/deps.sh" "$T/apply.sh" >/dev/null 2>&1 )
  reason="$(awk -F'\t' '$1=="7001"{print $5}' "$O/prdisp.tsv" 2>/dev/null)"
  case "$reason" in
    *sweep-rows.tsv*) ok "no-read row names the MISSING ARTEFACT (state/sweep-rows.tsv), not a vague 'or'" ;;
    *) bad "no-read row reason is '$reason'" ;;
  esac
fi

echo
echo "── Summary ───────────────────────────────────────────────────────"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] && echo "  ✅ all checks passed" || echo "  ❌ $FAIL check(s) failed"
[ "$FAIL" -eq 0 ]
