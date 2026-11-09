#!/usr/bin/env bash
# gh-bound.test.sh — the regression contract for agent-infra#2028.
#
# THE DEFECT. Every `gh` call in the controller's cycle body was UNBOUNDED, and
# `docs/ops/gh-rate-limits.md` states the limit it fell through ("The child `gh` has no timeout … a
# legitimate `gh` call's duration is not knowable here"), so the bound belongs at the CALL SITE. The
# shell call sites had none. MEASURED 2026-10-18: the `[res]` line's `gh api rate_limit` probe left a
# `gh` child alive for 2h 08m with 0.01 s CPU and no open sockets, while the supervisor reported the
# controller `running`; the same day `ps` showed eight `bash orch-loop.sh` processes 23-43 minutes old
# (ONE controller plus its substitution subshells, because a subshell inherits argv), and the REST
# quota was at 0/5000 with dispatch stopped and merges failing.
#
# HOW THESE CHECKS ARE WRITTEN. The shipped `# BEGIN gh-bound` / `# END gh-bound` block is extracted
# VERBATIM and driven against a stub `gh`, so every assertion is about the code that ships — never a
# re-implementation, which would pass on the broken copy too. NON-VACUITY: the pre-fix script carries
# no block, the extraction is empty, `need` fails, and every dependent check is RED. The structural
# check (every gh call in the loop goes through `gh_bounded`) is the one that keeps a NEW call site
# from re-introducing the defect silently.
#
# TWO BOUNDS, AND BOTH ARE GRADED, because they are different defects:
#   * the PER-CALL bound stops ONE hung call from pinning a substitution (`rc=124`, fast);
#   * the PER-CYCLE trip latch stops a window in which EVERY call hangs from costing
#     `bound x 2 x open_prs` — the measured 161-minute cycle body under another name.
#
# Run:  bash scripts/orchestrator-harness/gh-bound.test.sh

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOP="$HERE/orch-loop.sh"

PASS=0; FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ✅ $1"; }
bad() { FAIL=$((FAIL+1)); echo "  ❌ $1"; }
T="$(mktemp -d "${TMPDIR:-/tmp}/gh-bound.XXXXXX")"
trap 'rm -rf "$T"' EXIT
echo "==> gh bound contract ($HERE)"

[ -f "$LOOP" ] || { echo "  ❌ missing $LOOP"; exit 1; }

# need <file> <what> — a missing extraction must FAIL, not skip: if the shipped script lacks the block
# under test, the dependent checks would pass on an empty file (the sweep-quota.test.sh guard).
need() { if [ -s "$1" ]; then return 0; else bad "could not extract $2 from $LOOP"; return 1; fi; }

awk '/^# BEGIN gh-bound/,/^# END gh-bound/' "$LOOP" > "$T/block.sh"
need "$T/block.sh" "the gh-bound block" || { echo "==> 0 passed, 1 failed"; exit 1; }

# ── the stub `gh` ────────────────────────────────────────────────────────────────────────────────
# Records every argv to $GH_CALLS and then does what the case's GH_MODE says. `hang` SLEEPS far past
# any bound the case sets, which is the shape the fleet measured (a `gh` alive for 2h 08m).
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
case "${GH_MODE:-ok}" in
  ok)   printf '{"ok":1,"argv":"%s"}\n' "$*"; exit 0 ;;
  err)  printf 'boom\n' >&2; exit 7 ;;
  both) printf 'out\n'; printf 'warn\n' >&2; exit 3 ;;
  hang) sleep "${GH_HANG_S:-10}"; printf 'late\n'; exit 0 ;;
esac
exit 9
SH
chmod +x "$T/bin/gh"

# rig <outfile> — a runner that sources the SHIPPED block with a controlled O / script dir. Each case
# runs in its own process, so the block's startup resolution and its globals cannot leak between cases.
rig() {
  mkdir -p "$(dirname "$1")"
  {
    echo 'set -uo pipefail'
    echo 'O="$1"; LOG="$O/logs/orch-loop.log"; _HERE_RS="$2"; mkdir -p "$O/logs" "$O/state"'
    echo '. "$3"'
  } > "$1"
}
run_rig() { bash "$1" "$2" "$3" "$T/block.sh"; }

# Case A — a bounded call is BYTE-FOR-BYTE transparent on the success path. (The whole change rests on
# this: the call sites parse `--json` output, and two of them merge `2>&1` before parsing.)
A="$T/A"; rig "$A/rig.sh"
cat >> "$A/rig.sh" <<'SH'
out="$(gh_bounded pr view 7 --repo o/r --json state)"; rc=$?
printf 'rc=%s\nout=%s\n' "$rc" "$out"
GH_MODE=err gh_bounded api rate_limit >/dev/null 2>"$O/err"; printf 'rc_err=%s err=%s\n' "$?" "$(tr -d '\n' < "$O/err")"
merged="$(GH_MODE=both gh_bounded pr checks 7 2>&1)"; printf 'rc_both=%s merged=%s\n' "$?" "$(printf '%s' "$merged" | tr '\n' '|')"
SH
out="$(PATH="$T/bin:$PATH" GH_CALLS="$T/A.calls" GH_BOUND_S=1 run_rig "$A/rig.sh" "$T/oa" "$HERE" 2>&1)"
grep -qx 'rc=0' <<<"$out" && ok "success path: status preserved (0)" || bad "success path: rc was not 0 — got: $(echo "$out" | sed -n 1p)"
grep -qx 'out={"ok":1,"argv":"pr view 7 --repo o/r --json state"}' <<<"$out" \
  && ok "success path: stdout is the child's OWN bytes, unchanged (the call sites parse it)" \
  || bad "success path: stdout was rewritten — got: $(echo "$out" | sed -n 2p)"
grep -qx 'rc_err=7 err=boom' <<<"$out" && ok "failure path: the child's status AND stderr reach the caller untouched" \
  || bad "failure path: rc/stderr were not passed through — got: $(echo "$out" | sed -n 3p)"
grep -q 'rc_both=3 merged=out|warn' <<<"$out" \
  && ok "merged 2>&1 is unaltered: no diagnostic of ours rides a caller's parsed bytes" \
  || bad "merged 2>&1 was contaminated — got: $(echo "$out" | sed -n 4p)"
grep -q '^\[bound\] gh calls bounded at 1s' "$T/oa/logs/orch-loop.log" 2>/dev/null \
  && ok "startup: the resolved bound mechanism is recorded once, in the log" \
  || bad "startup: no [bound] line naming the bound in \$O/logs/orch-loop.log"

# Case B — the PER-CALL bound. A hung `gh` is killed and the caller gets 124 (GNU timeout's code), and
# it costs about the bound, not the hang.
B="$T/B"; rig "$B/rig.sh"
cat >> "$B/rig.sh" <<'SH'
t0=$(date +%s)
out="$(gh_bounded api rate_limit 2>/dev/null)"; rc=$?
printf 'rc=%s elapsed=%s out=%s\n' "$rc" "$(( $(date +%s) - t0 ))" "$out"
SH
out="$(PATH="$T/bin:$PATH" GH_CALLS="$T/B.calls" GH_MODE=hang GH_HANG_S=30 GH_BOUND_S=1 run_rig "$B/rig.sh" "$T/ob" "$HERE" 2>&1)"
grep -q '^rc=124 ' <<<"$out" && ok "hang: a gh call past the bound returns rc=124, not the hang's duration" \
  || bad "hang: the call did not answer 124 — got: $out"
el="$(echo "$out" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
{ [ -n "$el" ] && [ "$el" -le 4 ]; } && ok "hang: it cost about the 1 s bound (${el}s), not the 30 s hang" \
  || bad "hang: costing ${el:-?}s — the bound did not bound"
grep -q 'out=$' <<<"$out" && ok "hang: a killed call yields EMPTY output (never a fabricated answer)" \
  || bad "hang: a killed call produced output: $out"
grep -q 'hit the 1s bound and was killed' "$T/ob/logs/orch-loop.log" 2>/dev/null \
  && ok "hang: the kill is recorded in the log, naming the bound that fired" \
  || bad "hang: nothing in the log names the bound firing"

# Case C — the PER-CYCLE trip latch. After GH_BOUND_TRIP calls have hit the bound, the NEXT call fails
# fast WITHOUT spawning `gh` at all. (This is what stops a hung window from costing
# bound x 2 x open_prs — the measured 161-minute cycle body.)
C="$T/C"; rig "$C/rig.sh"
cat >> "$C/rig.sh" <<'SH'
for i in 1 2; do gh_bounded pr view "$i" >/dev/null 2>&1; done
before=$(grep -c . "${GH_CALLS:-/dev/null}" 2>/dev/null || echo 0)
t0=$(date +%s)
gh_bounded pr view 3 >/dev/null 2>&1; rc=$?
el=$(( $(date +%s) - t0 ))
after=$(grep -c . "${GH_CALLS:-/dev/null}" 2>/dev/null || echo 0)
printf 'trip: rc=%s elapsed=%s before=%s after=%s\n' "$rc" "$el" "$before" "$after"
# … and a TRUNCATED counter (what the cycle top does) re-arms it.
: > "$GH_BOUND_STATE"
gh_bounded pr view 4 >/dev/null 2>&1; rc2=$?
printf 'after-reset: rc=%s calls=%s\n' "$rc2" "$(grep -c . "${GH_CALLS:-/dev/null}" 2>/dev/null || echo 0)"
SH
out="$(PATH="$T/bin:$PATH" GH_CALLS="$T/C.calls" GH_MODE=hang GH_HANG_S=10 GH_BOUND_TRIP=2 GH_BOUND_S=1 run_rig "$C/rig.sh" "$T/oc" "$HERE" 2>&1)"
grep -q 'trip: rc=124' <<<"$out" && ok "trip: past GH_BOUND_TRIP a call still answers 124 (a refused read, not a hang)" \
  || bad "trip: a tripped call did not answer 124 — got: $out"
echo "$out" | sed -n 's/^trip: rc=124 elapsed=\([0-9]*\) .*/\1/p' | grep -qx 0 \
  && ok "trip: the tripped call cost 0 s — it spawned no gh at all" \
  || bad "trip: the tripped call still blocked — got: $out"
bf="$(echo "$out" | sed -n 's/^trip: rc=124 elapsed=[0-9]* before=\([0-9]*\).*/\1/p')"
af="$(echo "$out" | sed -n 's/^trip: rc=124 elapsed=[0-9]* before=[0-9]* after=\([0-9]*\).*/\1/p')"
{ [ -n "$bf" ] && [ -n "$af" ] && [ "$bf" = "$af" ]; } \
  && ok "trip: the stub gh was NOT invoked by the tripped call ($bf calls before and after)" \
  || bad "trip: the tripped call still reached gh (before=$bf after=$af)"
grep -q '^after-reset: rc=124 calls=' <<<"$out" && af2="$(echo "$out" | sed -n 's/^after-reset: rc=[0-9]* calls=\([0-9]*\).*/\1/p')" \
  && [ "${af2:-0}" -gt "${af:-0}" ] && ok "reset: an emptied counter re-arms the bound (the cycle top can reset it with a builtin)" \
  || bad "reset: emptying the counter did not re-arm the bound — got: $out"

# Case D — a knob that does not parse must NOT disarm every call. `tb_timeout` answers 125 (refusal,
# never run) for a non-integer bound, so an unvalidated GH_BOUND_S takes the controller dark.
D="$T/D"; rig "$D/rig.sh"
cat >> "$D/rig.sh" <<'SH'
out="$(gh_bounded pr view 7 2>/dev/null)"; rc=$?
printf 'rc=%s s=%s trip=%s out=%s\n' "$rc" "$GH_BOUND_S" "$GH_BOUND_TRIP" "$out"
SH
out="$(PATH="$T/bin:$PATH" GH_CALLS="$T/D.calls" GH_BOUND_S=abc GH_BOUND_TRIP=0 run_rig "$D/rig.sh" "$T/od" "$HERE" 2>&1)"
grep -q '^rc=0 s=120 trip=3 ' <<<"$out" \
  && ok "knobs: GH_BOUND_S=abc falls back to 120 s and the call still RUNS (never rc=125 for the whole cycle)" \
  || bad "knobs: an unparseable GH_BOUND_S was not repaired — got: $out"
grep -q 'GH_BOUND_S=abc does not parse' "$T/od/logs/orch-loop.log" 2>/dev/null \
  && ok "knobs: the repair is LOGGED, not silent (a no-op knob is how a typo becomes an outage)" \
  || bad "knobs: the GH_BOUND_S repair was silent"

# Case E — no bounded.sh at all: DEGRADED, DISCLOSED, and NOT a refusal to start. A controller that
# would not start because a bound it cannot find is missing is a worse outage than the bound prevents.
E="$T/E"; rig "$E/rig.sh"
cat >> "$E/rig.sh" <<'SH'
printf 'off=%s\n' "${GH_BOUND_OFF:-unset}"
out="$(GH_MODE=ok gh_bounded pr view 9 2>/dev/null)"; printf 'rc=%s out=%s\n' "$?" "$out"
SH
out="$(PATH="$T/bin:$PATH" HOME="$T/nohome" GH_CALLS="$T/E.calls" run_rig "$E/rig.sh" "$T/oe" "$T/nolib" 2>&1)"
grep -qx 'off=1' <<<"$out" && ok "degraded: no bounded.sh names itself (\$GH_BOUND_OFF=1) instead of refusing to run" \
  || bad "degraded: GH_BOUND_OFF was not set — got: $out"
grep -q '^rc=0 out={"ok":1' <<<"$out" && ok "degraded: calls still work (the bound is lost, the controller is not)" \
  || bad "degraded: a call failed — got: $out"
[ -s "$T/oe/state/gh-bound" ] && ok "degraded: state/gh-bound records it, so a reader can see the box is unbounded" \
  || bad "degraded: state/gh-bound was not written — the degradation is invisible"
grep -q 'DEGRADED' "$T/oe/logs/orch-loop.log" 2>/dev/null \
  && ok "degraded: the log says so" || bad "degraded: the log is silent"

# Case G — THE LAYER'S OWN IN-CALL WAITS ARE SUPPRESSED PER CALL (agent-infra#2028 review, P1). A 120 s
# bound against a layer that sleeps 60/120/240 s per refusal attempt, and up to 600 s in the lock, kills
# the call DURING a wait — so the RATE-LIMITED refusal never prints, the caller reads `other`, and the
# deferral is never armed. `GH_LIMIT_NO_WAIT` is the repo's documented seam for exactly this caller
# class. It must reach every call, and it must be put BACK afterwards so the lanes the controller spawns
# keep their own patience.
# Its OWN stub directory: this stub reports what it INHERITED (`in_call`), which is the only place the
# seam is observable, and rewriting the shared stub mid-suite would silently change what Cases A–E drove.
mkdir -p "$T/gbin"
cat > "$T/gbin/gh" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >> "${GH_CALLS:-/dev/null}"
printf '{"ok":1,"argv":"%s","in_call":"%s"}\n' "$*" "${GH_LIMIT_NO_WAIT-<unset>}"
SH
chmod +x "$T/gbin/gh"
G="$T/G"; rig "$G/rig.sh"
cat >> "$G/rig.sh" <<'SH'
printf 'child=%s\n' "$(gh_bounded pr view 7 2>/dev/null | sed -n 's/.*"in_call":"\([^"]*\)".*/\1/p')"
printf 'restored-unset=%s\n' "$(gh_bounded pr view 8 >/dev/null 2>&1; printf '%s' "${GH_LIMIT_NO_WAIT-<unset>}")"
SH
# `unset` in a subshell, not `env -u`: `run_rig` is a shell FUNCTION, and `env` can only exec a file on
# PATH — it died with `env: 'run_rig': No such file or directory` before the rig ran, which read as three
# reds over behaviour that was never exercised.
out="$( (unset GH_LIMIT_NO_WAIT; PATH="$T/gbin:$PATH" GH_CALLS="$T/G.calls" GH_BOUND_S=5 run_rig "$G/rig.sh" "$T/og" "$HERE") 2>&1)"
grep -qx 'child=1' <<<"$out" \
  && ok "no-wait: the controller's gh children carry GH_LIMIT_NO_WAIT=1 (the layer answers the refusal at once instead of sleeping past the bound)" \
  || bad "no-wait: the child did not inherit GH_LIMIT_NO_WAIT=1 — got: $(echo "$out" | sed -n 1p)"
grep -qx 'restored-unset=<unset>' <<<"$out" \
  && ok "no-wait: it is NOT left set on the controller (the lanes it spawns keep their own patience)" \
  || bad "no-wait: GH_LIMIT_NO_WAIT leaked into the controller — got: $(echo "$out" | sed -n 2p)"
# …and a caller's OWN value is restored to that value, never merely emptied.
G2="$T/G2"; rig "$G2/rig.sh"
cat >> "$G2/rig.sh" <<'SH'
GH_LIMIT_NO_WAIT=0; export GH_LIMIT_NO_WAIT
gh_bounded pr view 9 >/dev/null 2>&1
printf 'restored-caller=%s\n' "${GH_LIMIT_NO_WAIT-<unset>}"
SH
out2="$( (unset GH_LIMIT_NO_WAIT; PATH="$T/gbin:$PATH" GH_CALLS="$T/G2.calls" GH_BOUND_S=5 run_rig "$G2/rig.sh" "$T/og2" "$HERE") 2>&1)"
grep -qx 'restored-caller=0' <<<"$out2" \
  && ok "no-wait: a caller's OWN value is restored (set-ness preserved, never merely emptied)" \
  || bad "no-wait: a caller-set GH_LIMIT_NO_WAIT was not restored — got: $(echo "$out2" | sed -n 1p)"

# Case H — an UNUSABLE `TB_TIMEOUT_BIN` pin (agent-infra#2028 review, P2). `bounded.sh` resolves
# `TB_TIMEOUT_KIND=invalid` and leaves the pin set, so a presence check on `tb_timeout` alone passes
# while `tb_timeout` execs a nonexistent binary: rc=127 on EVERY call, with `state/gh-bound` deleted.
# That is a fully dark controller whose own state file says the bound is fine.
H="$T/H"; rig "$H/rig.sh"
cat >> "$H/rig.sh" <<'SH'
printf 'off=%s\n' "${GH_BOUND_OFF:-unset}"
out="$(GH_MODE=ok gh_bounded pr view 11 2>/dev/null)"; printf 'rc=%s out=%s\n' "$?" "$out"
SH
out="$(PATH="$T/bin:$PATH" GH_CALLS="$T/H.calls" TB_TIMEOUT_BIN="$T/no-such-timeout" run_rig "$H/rig.sh" "$T/oh" "$HERE" 2>&1)"
grep -qx 'off=1' <<<"$out" \
  && ok "bad pin: an unexecutable TB_TIMEOUT_BIN is DEGRADED, not announced as a working bound" \
  || bad "bad pin: the block claimed a bound it does not have — got: $out"
grep -q '^rc=0 out={"ok":1' <<<"$out" \
  && ok "bad pin: calls still RUN (rc=0, not the 127 every call would otherwise answer)" \
  || bad "bad pin: a call answered $(echo "$out" | sed -n 2p) — the controller is dark"
[ -s "$T/oh/state/gh-bound" ] && grep -q 'DEGRADED' "$T/oh/state/gh-bound" \
  && ok "bad pin: state/gh-bound records the degradation (it used to be DELETED on this path)" \
  || bad "bad pin: state/gh-bound does not record the degradation — a reader sees 'bounded'"
grep -q 'TB_TIMEOUT_BIN' "$T/oh/state/gh-bound" 2>/dev/null \
  && ok "bad pin: the record NAMES the pin, so the operator knows what to fix" \
  || bad "bad pin: the record does not name TB_TIMEOUT_BIN"
grep -q 'TB_TIMEOUT_FORCE_INTERNAL=1' "$T/oh/logs/orch-loop.log" 2>/dev/null \
  && ok "bad pin: the log names the remedy that does work (the internal watchdog)" \
  || bad "bad pin: the log names no remedy"

# Case I — ONE scratch dir for the whole controller, and it is reaped (agent-infra#2028 review note).
# Nine of the block's sixteen call sites are CAPTURED, and on a host whose watchdog resolves to the
# INTERNAL one (macOS: no GNU `timeout`, no `gtimeout`) every `tb_watchdog` creates `TB_BOUND_TMP` with
# `tb_bound_tmp` INSIDE that substitution's SUBSHELL — the assignment dies with the subshell, so no
# caller-side cleanup can see it. MEASURED pre-fix: one orphaned empty `bounded.XXXXXX` per captured
# call, for the life of a process that outlives a month of cycles. `bounded.sh`'s own documented fix
# (disk-reaper.sh) is to create it in the PARENT, which is what the block now does.
I="$T/I"; rig "$I/rig.sh"; mkdir -p "$T/itmp"
cat >> "$I/rig.sh" <<'SH'
for i in 1 2 3 4 5 6; do printf '%s' "$(gh_bounded pr view "$i" 2>/dev/null)" >/dev/null; done
printf 'dirs-after-calls=%s\n' "$(ls -1d "${TMPDIR:-/tmp}"/bounded.* 2>/dev/null | wc -l | tr -d ' ')"
gh_bound_cleanup
printf 'dirs-after-cleanup=%s\n' "$(ls -1d "${TMPDIR:-/tmp}"/bounded.* 2>/dev/null | wc -l | tr -d ' ')"
SH
out="$(PATH="$T/bin:$PATH" TMPDIR="$T/itmp" TB_TIMEOUT_FORCE_INTERNAL=1 GH_BOUND_S=5 run_rig "$I/rig.sh" "$T/oi" "$HERE" 2>&1)"
grep -qx 'dirs-after-calls=1' <<<"$out" \
  && ok "scratch: 6 captured calls share ONE scratch dir the parent created (pre-fix: one orphaned dir per call)" \
  || bad "scratch: the parent did not pre-create TB_BOUND_TMP — got $(echo "$out" | sed -n 1p) (want dirs-after-calls=1)"
grep -qx 'dirs-after-cleanup=0' <<<"$out" \
  && ok "scratch: the EXIT-trap helper reaps it (a month-long controller leaves nothing behind)" \
  || bad "scratch: gh_bound_cleanup did not remove the dir — got: $(echo "$out" | sed -n 2p)"
case "$(grep -n '^trap .*LOCKF' "$LOOP" | grep 'EXIT')" in
  *gh_bound_cleanup*) ok "scratch: the controller's EXIT trap calls gh_bound_cleanup (the helper is not dead code)" ;;
  *) bad "scratch: the EXIT trap does not reap the scratch dir — a killed controller leaves it behind" ;;
esac

# Case F — STRUCTURAL, and the one that keeps the fix from rotting: no gh call in the shipped loop may
# bypass the bound. The pre-fix tree fails this on 16 sites; a new unbounded call site fails it too.
# ⛔ ONE DEFINITION, TWO CALLERS (the real file and the mutation fixture below): a second copy of this
# expression is the "pin over a COPY" shape that let the verdict-extractor pin drift from its
# producer on this repo.
#
# FOUR PROPERTIES, all graded by the fixture below (agent-infra#2028 review rounds 2–5):
#  1. COMMAND POSITION IS SYNTACTIC, NOT A LAYOUT. `)` terminates a case PATTERN list wherever it
#     appears — the bash grammar is newline-agnostic (`case word in [ [(] pattern [| pattern ]...)
#     command-list ;;]... esac`, GNU Bash manual 3.2.5.2; measured: `bash -c 'help case'`), so a
#     line-anchored arm pattern sees only ONE of the two layouts. `orch-loop.sh` itself writes the
#     one-line form on 88 lines, e.g. `case "${_ghb_n:-}" in ''|*[!0-9]*) _ghb_n=0 ;; esac` — a
#     future unbounded call written that way would leave this scan EMPTY and this row GREEN. So `)`
#     is accepted at ANY offset, not only as the line's first token. (Measured: `awk '/case/ && / in /
#     && /\)/ && /;;/ && /esac/' orch-loop.sh | grep -vc '^[[:space:]]*#'` → 88, identical at
#     `origin/main`. An earlier 76 was not reproducible by any definition.)
#  2. A `)` INSIDE A LITERAL IS NEVER A COMMAND POSITION (quote removal happens before a command is
#     executed), so a quoted span is blanked before matching: `pattern="a) gh api"` cannot red it,
#     and the fixture has that control row so the claim is pinned rather than prose.
#  3. BUT A `$( … )` SUBSTITUTION INSIDE DOUBLE QUOTES RUNS, so it IS a command position. Blanking a
#     double-quoted span WHOLESALE was the fail-open this row shipped in review round 4: it removed
#     the repo's dominant capture idiom — `x="$(gh api …)"`, 9 of the block's 16 call sites, named at
#     `orch-loop.sh:519`, and the very pre-fix line the block above documents (`:4910`) — so an
#     unbounded call written that way left this scan EMPTY and this row GREEN. The stripper therefore
#     keeps the CODE inside `$( … )` and blanks only the literal text around it, so the
#     `$(`-anchored alternative sees the substitution exactly as it sees it unquoted. The `)` that
#     closes the substitution is re-emitted (so `$(cmd) gh …` still reads as a command position),
#     while a `)` that is merely literal text stays blanked. ShellCheck answers this by parsing to an
#     AST; a line regex cannot, so this is the next best thing — and the residue is a stated limit in
#     `docs/ops/gh-rate-limits.md`.
#  4. A command can also follow a shell KEYWORD or a wrapper word, not only a line start, `;`, `|`, or
#     `)`. `while` was already in the group; its sibling `until` was not, and neither were the `time`
#     and `exec` wrappers — so `until gh api …` / `time gh api …` passed this assertion GREEN while
#     the row's message said every command position was caught (agent-infra#2028 review round 5).
#     All four are in the group now, and rows 13–15 grade them. The residual is the whole WRAPPER
#     CLASS, not one spelling of it: of the wrapper words the group carries only `time` and `exec`
#     (its other members are the keywords `if`/`then`/`elif`/`while`/`until`/`!`/`do`/`else`), so
#     `env`, `nice`, `timeout`, `xargs`, `nohup` and `stdbuf` are unmodelled whether or NOT an
#     assignment follows — measured at this head (`env gh api …`, `env GH_TOKEN=x gh api …` and
#     `nice gh api …` are all invisible; `exec gh api …` reports). `sudo` is the sole exception, and
#     it errs CLOSED: the group is not word-anchored, so `do` matches the tail of `sudo ` and
#     `sudo gh api …` REDS (measured) — a false positive at worst, never a silent pass. That class is
#     named beside `variable` / `eval` / python heredoc / backtick in the runbook's stated limits, so
#     the remaining gap is disclosed, not implied closed.
#  5. AN ASSIGNMENT WORD BEFORE THE COMMAND WORD IS STILL A COMMAND POSITION. Bash's simple-command
#     grammar is `[assignment]… command [args]`, so `X=1 gh api …` runs `gh` exactly as `gh api …`
#     does — yet no anchor above matches it (there is no `)`, `|`, `;` or keyword in front of the
#     command word), so the scan stayed silent while its own row said every command position was
#     caught (agent-infra#2028 review round 8, measured: `X=1 gh api repos/o/r` and
#     `GH_HOST=example.com gh api repos/o/r` both reported NOTHING). The alternation therefore carries
#     one or more assignment words ahead of the optional `command` word, and rows 20–21 grade it —
#     `X=1 gh api …` MUST red and `X=1 gh_bounded api …` must NOT. The wrapper-word residual is
#     unchanged and still real: `env GH_TOKEN=x gh api …` stays invisible, because `env` is the
#     command word and the assignment sits BEHIND it (disclosed above and in the runbook).
_unbounded_scan() {
  awk '
  # code(<line>) -> the line with its LITERAL text REMOVED: single-quote spans in full, and the
  # non-code part of a double-quote span — whose `$( … )` substitutions are CODE and are emitted,
  # together with the `)` that closes them (see property 3 above). Quoting is modelled in full:
  # single quotes, double quotes, ANSI-C quoting (state A, where an escaped apostrophe does not close
  # the span), and the ESCAPE CHARACTER, which is a quoting mechanism in its own right (GNU Bash
  # manual §3.1.2) — so a backslash escapes in top-level code and inside a substitution, not only
  # inside double quotes. Modelling it ONLY inside double quotes was the round-6 fail-open: an escaped
  # quote in UNQUOTED position (`echo it\"s; gh api …`) is VALID bash, yet the escaped quote opened a
  # span and blanked the rest of the line — an under-report that could ship, while the sentence beside
  # it ruled that channel out as a syntax error. Rows 16-18 grade it (escaped apostrophe, escaped
  # double quote, ANSI-C quoting). Per-line state, deliberately: a multi-line string is re-scanned as
  # code on its continuation lines, so a `) gh` inside one is OVER-reported — fail-closed, never a
  # silent pass. `_stk`/`_pard` are the context stack (T = top-level code, D = double quote, S =
  # single quote, A = ANSI-C quoting, C = command substitution) and the paren depth inside each C;
  # they are globals because awk has no reentrancy here — `code()` is called once per record and
  # resets them on entry.
  function code(s,   n,i,c,out,sp,k,DQ,SQ) {
    n=length(s); out=""; sp=0; _stk[0]="T"; _pard[0]=0
    DQ=sprintf("%c",34); SQ=sprintf("%c",39)
    for (i=1;i<=n;i++) {
      c=substr(s,i,1); k=_stk[sp]
      if (k=="S") { if (c==SQ) sp--; continue }
      if (k=="A") { if (c=="\\") { i++; continue } if (c==SQ) sp--; continue }
      if (k=="D") {
        if (c=="\\") { i++; continue }
        if (c==DQ) { sp--; continue }
        if (c=="$" && substr(s,i+1,1)=="(") { out=out "$("; i++; sp++; _stk[sp]="C"; _pard[sp]=1; continue }
        continue
      }
      if (c=="\\") { i++; continue }
      if (c=="$" && substr(s,i+1,1)=="(") { out=out "$("; i++; sp++; _stk[sp]="C"; _pard[sp]=1; continue }
      if (c=="$" && substr(s,i+1,1)==SQ) { i++; sp++; _stk[sp]="A"; continue }
      if (c==DQ) { sp++; _stk[sp]="D"; continue }
      if (c==SQ) { sp++; _stk[sp]="S"; continue }
      if (k=="C") {
        if (c=="(") _pard[sp]++
        else if (c==")") { _pard[sp]--; if (_pard[sp]==0) { out=out c; sp--; continue } }
      }
      out = out c
    }
    return out
  }
  { line=$0; sub(/^[ \t]+/,"",line); if (line ~ /^#/) next;
    if (code(line) ~ /(^|[|;&({]|\$\(|(if|then|elif|while|until|!|do|else|time|exec)[ \t]|\))[ \t]*([A-Za-z_][A-Za-z0-9_]*=[^ \t]*[ \t]+)*(command[ \t]+)?gh[ \t]/) print NR": "line }' "$@" \
    | grep -v 'gh rc=%s' | grep -v 'then command gh "\$@"'
}
UNBOUNDED="$(_unbounded_scan "$LOOP")"
[ -z "$UNBOUNDED" ] && ok "structural: every gh invocation in orch-loop.sh goes through gh_bounded (0 unbounded sites)" \
  || bad "structural: unbounded gh call site(s) remain in orch-loop.sh:
$UNBOUNDED"
# …and the catcher itself must SEE every command position a call can be hidden in, or a future site
# written the other way passes with this assertion still green. Twenty lines, each graded:
#   1  a multi-line arm, unbounded              -> MUST be reported
#   2  a multi-line arm, already bounded        -> must NOT (else every case-arm site reds)
#   3  a ONE-LINE `case … in pat) gh api …`     -> MUST be reported (the form `orch-loop.sh` uses 88x)
#   4  `) gh` inside a double-quoted literal    -> must NOT (the string-literal property, pinned)
#   5  `) gh` inside a plain sentence             -> must NOT
#   6  `x="$(gh api …)"` — substitution in a double-quoted span -> MUST (property 3)
#   7  the same, inside an `if [ -n … ]` test                    -> MUST (property 3)
#   8  `x="$(command gh api …)"`                                 -> MUST (property 3)
#   9  the PRE-FIX capture idiom quoted from `orch-loop.sh:4910` -> MUST (property 3)
#  10  the same line UNQUOTED (`x=$(gh api …)`)                   -> MUST (the control showing rows
#      6–9 are not merely inheriting an alternation that only ever matched the unquoted form)
#  11  an already-BOUNDED capture (`x="$(gh_bounded api …)"`)     -> must NOT (no false positive)
#  12  a literal `) gh` AFTER a substitution in one quoted span    -> must NOT (that `)` is literal)
#  13  an `until` loop head (`while`'s keyword sibling)            -> MUST (property 4)
#  14  a `time` wrapper                                            -> MUST (property 4)
#  15  an `exec` wrapper                                           -> MUST (property 4)
#  16  an ESCAPED apostrophe in unquoted position (`it\'s`)         -> MUST (the escape character
#      must not open a span; valid bash, so round 6's under-report could ship)
#  17  the same, escaped double quote (`it\"s`)                     -> MUST (same channel)
#  18  an ANSI-C `$'a\'b'` quote (`\'` escapes INSIDE that span)     -> MUST (state A, same class)
#  19  a SINGLE-quoted literal carrying `) gh` (`pattern='a) gh api …'`) -> MUST NOT: property 2's
#      other spelling, state `S`. Without this row nothing pins single-quote stripping, so deleting
#      that state is undetected — its absence fails CLOSED (a literal would start red-ing), which is
#      why it is a row here rather than a finding; with it, property 2 holds for BOTH spellings.
#  20  an ASSIGNMENT-PREFIXED call (`X=1 gh api …`)                 -> MUST (property 5)
#  21  the same, already BOUNDED (`X=1 gh_bounded api …`)          -> must NOT (property 5: the
#      anchor reaches the command word, and `gh_bounded` is still not `gh`)
printf '%s\n' \
  'core) gh api repos/o/r/pulls' \
  '  other) gh_bounded api repos/o/r' \
  'case "$x" in pr) gh api repos/o/r ;; esac' \
  'pattern="a) gh api repos/o/r"' \
  'echo "1) gh is down"' \
  'X="$(gh api repos/o/r)"' \
  'if [ -n "$(gh api repos/o/r)" ]; then :; fi' \
  'Z="$(command gh api repos/o/r)"' \
  'OPEN_N="$(gh pr list --repo x --state open --limit 300 2>/dev/null)"; : "${OPEN_N:=0}"' \
  'Y=$(gh api repos/o/r)' \
  'rows="$(gh_bounded api repos/o/r)"' \
  'echo "a ($(date)) gh is down"' \
  'until gh api repos/o/r; do :; done' \
  'time gh api repos/o/r' \
  'exec gh api repos/o/r' \
  "echo it\\'s; gh api repos/o/r" \
  "echo it\\\"s; gh api repos/o/r" \
  "echo \$'a\\'b'; gh api repos/o/r" \
  "pattern='a) gh api repos/o/r'" \
  'X=1 gh api repos/o/r' \
  'X=1 gh_bounded api repos/o/r' > "$T/casearm.sh"
CASEARM="$(_unbounded_scan "$T/casearm.sh")"
if [ "$(awk -F: '{print $1}' <<<"$CASEARM" | tr '\n' ' ')" = "1 3 6 7 8 9 10 13 14 15 16 17 18 20 " ]; then
  ok "structural: every command position IS caught — both \`case\` layouts, the \`while\`/\`until\` loop heads, the \`time\`/\`exec\` wrappers, an assignment-prefixed call (\`X=1 gh api …\`), a \`\$( … gh …)\` substitution inside a double-quoted span (incl. the pre-fix capture idiom from orch-loop.sh:4910), AND an ESCAPED quote (\`it\\'s\`) or an ANSI-C \`\$'…'\` span around it — while a literal \`) gh\` in DOUBLE or SINGLE quotes and an already-bounded call (bare or assignment-prefixed) do not red it: the blind spot is closed, not documented"
else
  bad "structural: a command position is UNSCANNED — scan said '${CASEARM:-<nothing>}' (want lines 1, 3, 6, 7, 8, 9, 10, 13, 14, 15, 16, 17, 18 and 20 only)"
fi
# … and the ONE permitted bare `gh` is the degraded pass-through inside gh_bounded itself.
grep -q 'then command gh "\$@"' "$LOOP" && ok "structural: the degraded pass-through is the only bare gh, and it is inside gh_bounded" \
  || bad "structural: gh_bounded's degraded pass-through is missing (degraded mode would call nothing)"
# The cycle-top reset must be FORK-FREE: it sits above `fork_gate`, where a failed fork TERMINATES the
# controller (#2293), so `rm` there would be a one-line outage on a fork-starved box.
grep -qx '  : > "\$GH_BOUND_STATE" 2>/dev/null || true' "$LOOP" \
  && ok "structural: the per-cycle reset is a builtin truncation (':' + redirect), not \`rm\` — it sits above fork_gate" \
  || bad "structural: the cycle-top reset of the trip counter is missing"

echo
echo "==> $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
