#!/usr/bin/env bash
# worker-terminal.test.sh — the worker launcher and the controller's portability, driven.
#
# TWO MEASURED FACTS THIS SUITE PINS (2026-10-20, all three cloud cells):
#   1. A lane launched as a tmux window (or a `setsid nohup` child of a transient `cmux cloud exec`
#      session) dies at ~21 log lines — its first `bash` tool call never returns and its transcript
#      stops after ONE toolCall. The SAME lane in a DURABLE TERMINAL survives. So: the shipped
#      launchers may not start a worker with `tmux new-session`/`setsid`/`nohup`, the spawn must go
#      to a daemon-owned terminal, and a Linux host with no such surface must REFUSE rather than
#      silently fall back to the launcher that kills lanes.
#   2. `orch-loop.sh`'s capacity probes must answer on Linux as well as macOS. agent-infra#1702's
#      portable helpers are already shipped; what was NOT pinned is the macOS SHAPE of the stat probe
#      (`stat -f %m` succeeding while `stat -c %Y` fails) — unreachable on a Linux CI host without a
#      stub, and the shape that decides whether a cell reaps or aborts. Both shapes are driven here.
#
# HOW: the stubs are FILES on PATH (`cmux`, `tmux`, `uname`, `stat`), because the modules under test
# call them by name — so what runs is the real shipped code, not a re-implementation. Every assertion
# reads an ARTIFACT: the surface's recorded argv, the record file, the run script, a log line.
#
# Hermetic: no network, no tmux server, no cmux daemon, no git writes. Run: bash worker-terminal.test.sh
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/worker-terminal.sh"
LOOP="$HERE/orch-loop.sh"
DM="$HERE/dispatch-merge.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0; FAIL=0
ck() { # ck <name> <0|1>
  if [ "$2" -eq 0 ]; then printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASS=$((PASS+1));
  else printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAIL=$((FAIL+1)); fi
}

# ── the fake surface ───────────────────────────────────────────────────────────
# ONE stub, parameterised by env, installed into each scenario's bin dir. It answers the guest CLI's
# grammar (`tree`, `layout apply`, `terminal close`, `workspace rm`) and refuses `surface` exactly as
# the cell's CLI does (`cmux: unknown resource scope "surface"`, measured on cell-3) — unless
# CMUX_HOST=1, which models the Mac host CLI and its `surface` scope.
mkdir -p "$TMP/stub"
cat > "$TMP/stub/cmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "CMUX $*" >> "${CMUX_LOG:-/dev/null}"
if [ "${CMUX_ABSENT:-0}" = "1" ]; then echo "cmux: no daemon" >&2; exit 1; fi
case "${1:-}" in
  tree)
    [ "${CMUX_TREE_FAIL:-0}" = "1" ] && { echo "cmux: cannot read" >&2; exit 1; }
    # A SEQUENCED tree: the daemon answers differently on the nth call (a close is verified against a
    # SECOND read). `$CMUX_TREE_SEQ.1`, `.2`, … with `.last` as the fallback.
    if [ -n "${CMUX_TREE_SEQ:-}" ]; then
      _n=$(cat "$CMUX_TREE_SEQ.n" 2>/dev/null || echo 0); _n=$((_n+1)); printf '%s\n' "$_n" > "$CMUX_TREE_SEQ.n"
      for _f in "$CMUX_TREE_SEQ.$_n" "$CMUX_TREE_SEQ.last"; do
        [ -f "$_f" ] && { cat "$_f"; exit 0; }
      done
      echo "cmux: no such sequence step" >&2; exit 1
    fi
    # A RAW answer, byte for byte (a banner line, a drifted shape — anything the parser may refuse).
    [ -n "${CMUX_TREE_RAW:-}" ] && { printf '%s\n' "$CMUX_TREE_RAW"; exit 0; }
    # ⛔ NOT `${CMUX_TREE_JSON:-{...}}`: brace nesting inside that expansion makes bash emit the
    # value PLUS a literal `}` — a stub bug that turns valid JSON into `Extra data` and reads as
    # "the census saw nothing", i.e. every worker dead. Measured here before it was fixed.
    if [ -n "${CMUX_TREE_JSON:-}" ]; then printf '%s\n' "$CMUX_TREE_JSON"
    else printf '%s\n' '{"workspaces":[],"screens":[],"tabs":[],"terminals":[]}'; fi
    ;;
  surface)
    [ "${CMUX_HOST:-0}" = "1" ] || { echo 'cmux: unknown resource scope "surface"' >&2; exit 1; }
    if [ "${2:-}" = "ls" ]; then exit 0; fi
    if [ "${2:-}" = "new-terminal" ]; then printf 'surface:term_host42\n'; exit 0; fi
    ;;
  layout)
    [ "${CMUX_LAYOUT_RC:-0}" = "0" ] || { echo "cmux: layout apply failed" >&2; exit "${CMUX_LAYOUT_RC}"; }
    cat >/dev/null 2>&1 || true          # the layout document arrives on stdin
    if [ "${CMUX_NO_ID:-0}" = "1" ]; then printf '{"warnings": []}\n'; exit 0; fi
    # a workspace with NO terminal id: the create half-succeeded, so the refusal must undo it
    if [ "${CMUX_NO_ID_WS:-0}" = "1" ]; then printf '{"workspace_id": "ws_half9"}\n'; exit 0; fi
    printf '{"workspace_id": "ws_%s", "panes": [{"surfaces": [{"terminal_id": "term_%s"}]}]}\n' \
      "${CMUX_WS_SUFFIX:-x}" "${CMUX_WS_SUFFIX:-x}"
    ;;
  terminal)
    [ "${2:-}" = "close" ] && printf '%s\n' "${3:-}" >> "${CMUX_CLOSED:-/dev/null}"
    ;;
  workspace) : ;;
esac
exit 0
SH
chmod +x "$TMP/stub/cmux"
# The tmux side: a session list and a spawn/kill recorder. A test that a spawn did NOT reach tmux is
# only meaningful because this stub WOULD have recorded it.
cat > "$TMP/stub/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "TMUX $*" >> "${TMUX_LOG:-/dev/null}"
# The session list lives in a FILE because `kill-session` must actually remove the session: a stub
# that only records the kill would leave the list intact, and a close that is VERIFIED against it
# could never be observed to succeed — the assertion would pass for the wrong reason.
st="${TMUX_STATE:-}"
case "${1:-}" in
  ls) if [ "${TMUX_LS_FAIL:-0}" = "1" ]; then
        # tmux's own broken-socket answer: an ERROR, not "no sessions". The two must not read alike.
        echo "error connecting to /tmp/tmux-501/default (No such file or directory)"; exit 1
      fi
      [ -n "$st" ] && [ -f "$st" ] && sed '/^$/d' "$st" ;;
  # ⛔ a pid that CANNOT exist (above pid_max): `wt_close` really does `kill -TERM`/`-KILL` it, and a
  # plausible number here signalled whatever unrelated process happened to own it during a test run.
  list-panes) printf '%s\n' "${TMUX_PANE_PID:-4194305}" ;;
  new-session) [ "${TMUX_SPAWN_RC:-0}" = "0" ]; [ -n "$st" ] && printf '%s\n' "${4#=}" >> "$st" ;;
  # The LOG keeps the target VERBATIM (the `=` prefix is the assertion); the STATE file needs the
  # bare name so membership still matches.
  kill-session) printf '%s\n' "${3:-}" >> "${TMUX_KILLED:-/dev/null}"; t="${3#=}"
                [ -n "$st" ] && [ -f "$st" ] && { grep -vx -- "$t" "$st" > "$st.n"; mv "$st.n" "$st"; } ;;
esac
exit 0
SH
chmod +x "$TMP/stub/tmux"
cat > "$TMP/stub/uname" <<'SH'
#!/usr/bin/env bash
echo "${FAKE_UNAME:-Linux}"
SH
chmod +x "$TMP/stub/uname"
# scenario <name> — a bin dir whose stubs are the ones above (first on PATH, so they shadow the real
# cmux/uname/tmux a developer box or a cell may have).
scenario() { mkdir -p "$TMP/bin-$1"; cp "$TMP/stub/cmux" "$TMP/stub/tmux" "$TMP/stub/uname" "$TMP/bin-$1/"; }
scenario cmux; scenario absent; scenario darwin; scenario host

# lib <scenario> <O> — a shell with the SHIPPED library sourced and nothing else set up.
librun() { # librun <dir-name> <script-text...>
  local d="$1"; shift
  ( set -u
    PATH="$TMP/bin-$d:$PATH"
    O="$2"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
    # shellcheck disable=SC1090
    . "$LIB" )
}

echo
echo "── A) the shipped launchers do not start a worker with a bare detached process ──"
# ⛔ THE GREPS BELOW ARE ON THE SHIPPED FILES, and they are NON-VACUOUS: a synthetic file carrying
# each banned shape is fed through the same predicates at the end of this block.
n_spawn="$(grep -c 'tmux new-session' "$LOOP" "$DM" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
[ "$n_spawn" = "0" ] && rc=0 || rc=1
ck "orch-loop.sh and dispatch-merge.sh contain NO \`tmux new-session\` worker spawn (found $n_spawn)" $rc
n_detach="$(grep -cE '(setsid|nohup)[^#]*\bpi\b' "$LOOP" "$DM" 2>/dev/null | awk -F: '{s+=$2} END{print s+0}')"
[ "$n_detach" = "0" ] && rc=0 || rc=1
ck "…and no \`setsid\`/\`nohup\` pi spawn (the transient-exec shape that dies at ~21 lines)" $rc
# The tmux branch still exists, but ONLY on the launchd surface and only inside the launcher module.
n_lib="$(grep -c 'tmux new-session' "$LIB")"
[ "$n_lib" = "1" ] && rc=0 || rc=1
ck "the ONE remaining tmux spawn lives in worker-terminal.sh (found $n_lib)" $rc
grep -q 'elif \[ "$(uname -s 2>/dev/null)" = "Darwin" \]' "$LIB" && rc=0 || rc=1
ck "…and it is reachable only on macOS-without-cmux (the launchd surface)" $rc
# Both launchers must source the module AND validate EVERY verb they call (a narrower guard passes a
# module that is present but partial, and the controller then logs `launcher=` and a false 0 workers).
for f in "$LOOP" "$DM"; do
  rc=0
  grep -q 'worker-terminal.sh' "$f" || rc=1
  grep -q 'for _wt_v in wt_spawn' "$f" || rc=1
  grep -q 'command -v "$_wt_v"' "$f" || rc=1
  grep -q 'wt_close wt_launcher' "$f" || rc=1
  [ "$rc" -eq 0 ] || break
done
ck "…and both launchers source it and REFUSE to run without EVERY verb they call" $rc
# NON-VACUITY: the predicates must fire on a planted shape, or they prove nothing about the files.
printf 'tmux new-session -d -s "lane-1" "pi -p x"\nsetsid nohup pi -p y\n' > "$TMP/planted.sh"
grep -q 'tmux new-session' "$TMP/planted.sh" && grep -qE '(setsid|nohup)[^#]*\bpi\b' "$TMP/planted.sh" && rc=0 || rc=1
ck "non-vacuity: the banned-shape predicates DO fire on a planted spawn" $rc

echo
echo "── B) a spawn is a DURABLE TERMINAL, and a failed one leaves nothing behind ──"
cat > "$TMP/b1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
# exported: the stubs are CHILD PROCESSES, so a plain assignment would be invisible to them —
# and every assertion below about a stub ("it was never called") would pass vacuously.
export CMUX_LOG="$4"; : > "$CMUX_LOG"
. "$1"
echo "launcher=$(wt_launcher) grammar=$(wt_grammar)"
wt_spawn "lane-7" "/tmp" 'bash /tmp/lane.sh 7 feat/7-tm owner/repo'; echo "rc=$?"
SH
out="$(bash "$TMP/b1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O1" "$TMP/cmux1.log" 2>&1)"
case "$out" in *"launcher=terminal"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a cmux surface selects the durable-terminal launcher" $rc
case "$out" in *"rc=0"*) rc=0 ;; *) rc=1;; esac
ck "…and the spawn succeeds" $rc
grep -q 'layout apply --name wt-lane-7 --cwd /tmp' "$TMP/cmux1.log" && rc=0 || rc=1
ck "…by asking the daemon for a terminal surface named wt-<worker> in the worker's cwd" $rc
grep -qx 'kind=terminal' "$TMP/O1/state/worker-lane-7" && rc=0 || rc=1
ck "…and recording the terminal so the reaper can find it" $rc
[ -x "$TMP/O1/state/run-lane-7.sh" ] && rc=0 || rc=1
ck "…with an executable run script (the exact command, readable by an operator)" $rc
grep -qF "bash /tmp/lane.sh 7 feat/7-tm owner/repo" "$TMP/O1/state/run-lane-7.sh" && rc=0 || rc=1
ck "…that carries the caller's command verbatim" $rc
[ "$(stat -c '%a' "$TMP/O1/state/env-lane-7.sh" 2>/dev/null || stat -f '%Lp' "$TMP/O1/state/env-lane-7.sh")" = "600" ] && rc=0 || rc=1
ck "the env snapshot (the keys the terminal does NOT inherit) is written 0600" $rc
grep -q '^export O=' "$TMP/O1/state/env-lane-7.sh" && rc=0 || rc=1
ck "…and it carries O, which a durable terminal would otherwise lose" $rc
# A failed create must NOT look like a worker: no record, no run script, non-zero rc.
rm -rf "$TMP/O2"; CMUX_LAYOUT_RC=1 bash "$TMP/b1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O2" "$TMP/cmux2.log" >"$TMP/b2.out" 2>&1
grep -q 'rc=1' "$TMP/b2.out" && [ ! -f "$TMP/O2/state/worker-lane-7" ] && rc=0 || { rc=1; cat "$TMP/b2.out"; }
ck "a create that FAILS returns non-zero and records NO worker (no phantom)" $rc
grep -q 'REFUSED lane-7' "$TMP/b2.out" && rc=0 || rc=1
ck "…and says why, naming the worker" $rc
# A create that succeeds but prints no id is a terminal nobody can reap — treated as a failure.
rm -rf "$TMP/O3"; CMUX_NO_ID=1 bash "$TMP/b1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O3" "$TMP/cmux3.log" >"$TMP/b3.out" 2>&1
grep -q 'rc=1' "$TMP/b3.out" && [ ! -f "$TMP/O3/state/worker-lane-7" ] && rc=0 || { rc=1; cat "$TMP/b3.out"; }
ck "a terminal with NO readable id is refused (an untrackable worker cannot be reaped)" $rc
# …and the HALF-CREATED workspace is undone, not leaked: a create that returns a workspace but no
# terminal leaves an unowned surface behind, and nothing could ever close it (no record, no id).
rm -rf "$TMP/O3b"; CMUX_NO_ID_WS=1 bash "$TMP/b1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O3b" "$TMP/cmux3b.log" >"$TMP/b3b.out" 2>&1
grep -q 'CMUX workspace rm ws_half9' "$TMP/cmux3b.log" && rc=0 || { rc=1; cat "$TMP/cmux3b.log"; }
ck "…and the workspace that create had already made is REMOVED, not leaked" $rc

echo
echo "── C) a cell with no cmux surface REFUSES — it never falls back to tmux ──"
cat > "$TMP/c1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; LOG="$O/test.log"; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_LOG="$4"; : > "$TMUX_LOG"
. "$1"
echo "launcher=$(wt_launcher)"
wt_spawn "lane-8" "/tmp" 'bash /tmp/lane.sh 8 b o/r'; echo "rc=$?"
SH
out="$(FAKE_UNAME=Linux bash "$TMP/c1.sh" "$LIB" "$TMP/bin-absent" "$TMP/O4" "$TMP/tmux4.log" 2>&1)"
case "$out" in *"launcher=none"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "no cmux + Linux => launcher=none (the surface fact is reported, not guessed)" $rc
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1;; esac
ck "…and the spawn is REFUSED" $rc
[ -s "$TMP/tmux4.log" ] && rc=1 || rc=0
ck "…WITHOUT falling back to tmux (the launcher that kills lanes) — tmux was never called" $rc
grep -q 'REFUSED lane-8' "$TMP/O4/test.log" && rc=0 || rc=1
ck "…and the refusal reaches the controller's log, not just stderr" $rc

echo
echo "── D) the launchd surface still uses tmux (the one place it is correct) ──"
cat > "$TMP/d1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_LOG="$4" TMUX_KILLED="$5" TMUX_PANE_PID=4194305
# The session list carries this worker (and a peer, to prove the membership test is exact).
export TMUX_STATE="$O/tmux-sessions"; printf 'lane-9\nmerge-9\n' > "$TMUX_STATE"
: > "$TMUX_LOG"; : > "$TMUX_KILLED"
. "$1"
echo "launcher=$(wt_launcher)"
wt_spawn "lane-9" "/tmp" 'bash /tmp/lane.sh 9 b o/r'; echo "spawn_rc=$?"
echo "alive=$(wt_alive lane-9 && echo yes || echo no)"
wt_close lane-9; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-lane-9" ] && echo kept || echo gone)"
SH
out="$(FAKE_UNAME=Darwin bash "$TMP/d1.sh" "$LIB" "$TMP/bin-darwin" "$TMP/O5" "$TMP/tmux5.log" "$TMP/killed5.log" 2>&1)"
case "$out" in *"launcher=tmux"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "no cmux + macOS => launcher=tmux (launchd cannot reach the cmux daemon by design)" $rc
grep -q 'TMUX new-session -d -s lane-9' "$TMP/tmux5.log" && rc=0 || rc=1
ck "…and the spawn is a tmux session, exactly as before" $rc
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1;; esac
ck "…whose liveness is read from the session list" $rc
grep -qx '=lane-9' "$TMP/killed5.log" && rc=0 || rc=1
ck "…and closed with an EXACT session target (=name), never a prefix match" $rc
case "$out" in *"record=gone"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…removing its record once the kill is verified" $rc

echo
echo "── E) the census is fail-CLOSED: an unreadable surface counts as ALIVE ──"
cat > "$TMP/e1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
printf 'kind=terminal\nid=term_x\nworkspace=ws_x\n' > "$WT_DIR/worker-fix-3"
export CMUX_TREE_FAIL=1
. "$1"
echo "alive=$(wt_alive fix-3 && echo yes || echo no)"
echo "count=$(wt_count fix-)"
echo "absent=$(wt_alive fix-999 && echo yes || echo no)"
SH
out="$(bash "$TMP/e1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O6" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a worker whose surface cannot be read is ALIVE, not dead (a kill needs positive evidence)" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…so the concurrency ceiling keeps BINDING when the daemon is in trouble" $rc
case "$out" in *"absent=no"*) rc=0 ;; *) rc=1;; esac
ck "…while a name this box has never heard of is NOT a worker" $rc

echo
echo "── F) a kill that cannot be PROVEN is not reported as one ──"
cat > "$TMP/f1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
# The surface still lists the workspace after `terminal close` (a daemon that ignored the close).
export CMUX_TREE_JSON='{"workspaces":[{"id":"ws_fix-4","name":"wt-fix-4"}],"screens":[{"id":"s1","workspace_id":"ws_fix-4","layout":{"root":{"tab_ids":["t1"]}}}],"tabs":[{"id":"t1","content_id":"term_fix-4"}],"terminals":[{"id":"term_fix-4","running":true}]}'
printf 'kind=terminal\nid=term_fix-4\nworkspace=ws_fix-4\n' > "$WT_DIR/worker-fix-4"
. "$1"
wt_close fix-4; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-fix-4" ] && echo kept || echo gone)"
SH
out="$(bash "$TMP/f1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O7" 2>&1)"
case "$out" in *"close_rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a worker still present after the close returns non-zero" $rc
case "$out" in *"record=kept"*) rc=0 ;; *) rc=1;; esac
ck "…and its record is KEPT, so the next cycle retries instead of leaking the slot" $rc

echo
echo "── G) the named primitive, when the installed CLI has it ──"
cat > "$TMP/g1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_HOST=1 CMUX_LOG="$4" WT_MACHINE=vm-abc; : > "$CMUX_LOG"
. "$1"
echo "grammar=$(wt_grammar)"
wt_spawn "merge-5" "/tmp" 'bash /tmp/merge-one.sh --argv /tmp/a'; echo "rc=$?"
SH
out="$(bash "$TMP/g1.sh" "$LIB" "$TMP/bin-host" "$TMP/O8" "$TMP/cmux8.log" 2>&1)"
case "$out" in *"grammar=surface"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a CLI with the \`surface\` scope selects that grammar" $rc
grep -q 'CMUX surface new-terminal --machine vm-abc --cwd /tmp --no-open -- /bin/bash .*run-merge-5.sh' "$TMP/cmux8.log" && rc=0 || rc=1
ck "…and spawns with the named primitive: --machine/--cwd/--no-open and the run script" $rc
grep -qx 'grammar=surface' "$TMP/O8/state/worker-merge-5" && rc=0 || rc=1
ck "…recording which grammar produced it" $rc

echo
echo "── I) a surface-grammar worker is TRACKED BY ITS TERMINAL ID (it has no workspace name) ──"
# ⛔ `surface new-terminal` takes no name, so the layout grammar's `wt-<worker>` workspace does not
# exist for it. Keying the census on that name alone read such a worker DEAD: the caps stopped
# binding, `sess()` re-spawned the same PR every cycle, and dispatch-merge released a claim while the
# lane ran. The id from the record is the handle, so the census must resolve it.
cat > "$TMP/i1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_HOST=1 CMUX_LOG="$4" WT_MACHINE=vm-abc
# the tree knows the terminal by ID and by no workspace name at all
export CMUX_TREE_JSON='{"workspaces":[],"screens":[],"tabs":[],"terminals":[{"id":"term_host42","running":true}]}'
: > "$CMUX_LOG"
. "$1"
wt_spawn "merge-5" "/tmp" 'bash /tmp/merge-one.sh --argv /tmp/a'; echo "rc=$?"
echo "alive=$(wt_alive merge-5 && echo yes || echo no)"
echo "count=$(wt_count merge-)"
SH
out="$(bash "$TMP/i1.sh" "$LIB" "$TMP/bin-host" "$TMP/O9" "$TMP/cmux9.log" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a worker whose surface has no workspace name is still ALIVE (resolved by terminal id)" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…and the concurrency ceiling COUNTS it" $rc
# The same census, with the terminal no longer running: a POSITIVE read, so DEAD is allowed.
cat > "$TMP/i2.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_JSON='{"workspaces":[],"screens":[],"tabs":[],"terminals":[{"id":"term_host42","running":false}]}'
printf 'kind=terminal\nid=term_host42\nworkspace=\n' > "$WT_DIR/worker-merge-5"
. "$1"
echo "alive=$(wt_alive merge-5 && echo yes || echo no)"
SH
out="$(bash "$TMP/i2.sh" "$LIB" "$TMP/bin-host" "$TMP/O10" 2>&1)"
case "$out" in *"alive=no"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…and a terminal the daemon says is NOT running reads DEAD (a positive read, not a guess)" $rc

echo
echo "── J) an unreadable tmux session list is UNKNOWN, never 'no sessions' ──"
# ⛔ The 2026-10-20 polarity bug, second half: `tmux ls || true` folded a failed read into an empty
# list, so a broken socket read as "every tmux worker is gone" — `wt_count` stopped binding the caps
# and `wt_close` DELETED the record of a session that was still running.
cat > "$TMP/j1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_STATE="$O/tmux-sessions" TMUX_LOG="$O/tmux.log" TMUX_KILLED="$O/killed.log" TMUX_PANE_PID=4194305
export TMUX_LS_FAIL=1
printf 'merge-9\n' > "$TMUX_STATE"
printf 'kind=tmux\ncwd=/tmp\n' > "$WT_DIR/worker-merge-9"
. "$1"
echo "alive=$(wt_alive merge-9 && echo yes || echo no)"
echo "count=$(wt_count merge-)"
wt_close merge-9; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-merge-9" ] && echo kept || echo gone)"
SH
out="$(FAKE_UNAME=Darwin bash "$TMP/j1.sh" "$LIB" "$TMP/bin-darwin" "$TMP/O11" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a failed tmux read leaves its worker ALIVE (unknown is alive)" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…so the caps keep binding through a broken socket" $rc
case "$out" in *"close_rc=1"*) rc=0 ;; *) rc=1;; esac
ck "…and a close it cannot VERIFY returns non-zero" $rc
case "$out" in *"record=kept"*) rc=0 ;; *) rc=1;; esac
ck "…keeping the record, so the reap retries instead of claiming a kill it never proved" $rc
# Control: tmux's REAL absent answer still reads as no sessions (otherwise the fix would brick a box
# that simply has no server, which is the normal state on a fresh Mac).
cat > "$TMP/j2.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_ABSENT=1 TMUX_STATE="$O/none" TMUX_LOG="$O/tmux.log"
. "$1"
printf 'kind=tmux\ncwd=/tmp\n' > "$WT_DIR/worker-merge-9"
echo "alive=$(wt_alive merge-9 && echo yes || echo no)"
SH
out="$(FAKE_UNAME=Darwin bash "$TMP/j2.sh" "$LIB" "$TMP/bin-darwin" "$TMP/O12" 2>&1)"
case "$out" in *"alive=no"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…while 'no server running' (the real absent answer) is still a positive EMPTY read" $rc

echo
echo "── K) the census memo is a FILE, so a cycle's questions are ONE daemon read ──"
# ⛔ Every call site reads the table through `$(wt_table)`, so the in-shell memo never survived the
# subshell: three questions produced three `cmux tree` probes. Pinned here as a COUNT, because the
# claim ("one daemon read per table") is otherwise unobservable from outside.
cat > "$TMP/k1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=10; mkdir -p "$WT_DIR"
export CMUX_LOG="$4"; : > "$CMUX_LOG"
. "$1"
printf 'kind=terminal\nid=term_host42\nworkspace=\n' > "$WT_DIR/worker-merge-5"
export CMUX_TREE_JSON='{"workspaces":[],"screens":[],"tabs":[],"terminals":[{"id":"term_host42","running":true}]}'
x="$(wt_alive merge-5 && echo yes)"; y="$(wt_count merge-)"; z="$(wt_alive merge-5 && echo yes)"
echo "answers=$x/$y/$z probes=$(grep -c 'CMUX tree' "$CMUX_LOG")"
SH
out="$(bash "$TMP/k1.sh" "$LIB" "$TMP/bin-host" "$TMP/O13" "$TMP/cmux13.log" 2>&1)"
case "$out" in *"probes=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "three separate census questions cost ONE daemon read (the memo survives the subshell)" $rc
case "$out" in *"answers=yes/1/yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…and the memo answers all three correctly" $rc

echo
echo "── L) a spawn that cannot RECORD itself is not a success ──"
# ⛔ A terminal created without a record is untrackable: the census still sees the surface (the slot is
# held) while `wt_close` has no id to close, so the worker holds a slot the reaper can never free.
cat > "$TMP/l1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_LOG="$4" CMUX_CLOSED="$5"; : > "$CMUX_LOG"; : > "$CMUX_CLOSED"
mkdir -p "$WT_DIR/worker-lane-7"          # the record path is a DIRECTORY: the write must fail
. "$1"
wt_spawn "lane-7" "/tmp" 'bash /tmp/lane.sh 7 b o/r'; echo "rc=$?"
SH
out="$(bash "$TMP/l1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O14" "$TMP/cmux14.log" "$TMP/closed14.log" 2>&1)"
case "$out" in *"rc=1"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a record that cannot be written FAILS the spawn (no untrackable worker)" $rc
grep -q 'REFUSED lane-7' <<<"$out" && rc=0 || rc=1
ck "…naming the worker and the reason" $rc
[ -s "$TMP/closed14.log" ] && rc=0 || rc=1
ck "…and CLOSING the terminal it had just created instead of leaking it" $rc

echo
echo "── M) a daemon answer the parser cannot read is UNKNOWN, not 'every worker is dead' ──"
# ⛔ The census's readability test was "did the daemon print something". A reply the parser refuses (a
# banner line before the JSON, a shape that drifted between cmux builds) is non-empty and unparseable:
# every terminal record then read DEAD, the caps stopped binding, and `wt_close` DELETED a live
# worker's record — a false PASS on the one gate whose whole job is proving a kill.
cat > "$TMP/m1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
# A warning line first, then perfectly valid JSON that says the terminal IS running.
export CMUX_TREE_RAW='warning: cmux 0.1.1 available
{"workspaces":[],"screens":[],"tabs":[],"terminals":[{"id":"term_live","running":true}]}'
printf 'kind=terminal\nid=term_live\nworkspace=\n' > "$WT_DIR/worker-merge-77"
. "$1"
echo "alive=$(wt_alive merge-77 && echo yes || echo no)"
echo "count=$(wt_count merge-)"
wt_close merge-77; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-merge-77" ] && echo kept || echo gone)"
SH
out="$(bash "$TMP/m1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O15" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "an unparseable census reply leaves its worker ALIVE" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…so the caps keep binding when a cmux build prints a banner" $rc
case "$out" in *"close_rc=1"*) rc=0 ;; *) rc=1;; esac
ck "…and a close it cannot verify returns non-zero" $rc
case "$out" in *"record=kept"*) rc=0 ;; *) rc=1;; esac
ck "…instead of deleting a live worker's record (a false PASS on the reap gate)" $rc
# ⛔ SYNTAX IS NOT SHAPE. A reply that PARSES but no longer carries the tree (an envelope, a renamed
# `terminals`) used to produce a table of `dead` rows with the probe reporting SUCCESS — the same
# false PASS by a quieter route, and the header records that cmux builds already differ in shape.
cat > "$TMP/m2.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_RAW='{"data":{"workspaces":[],"screens":[],"tabs":[],"terminals":[{"id":"term_live","running":true}]}}'
printf 'kind=terminal
id=term_live
workspace=\n' > "$WT_DIR/worker-merge-78"
. "$1"
echo "alive=$(wt_alive merge-78 && echo yes || echo no)"
echo "count=$(wt_count merge-)"
wt_close merge-78; echo "close_rc=$?"
echo "record=$([ -f "$WT_DIR/worker-merge-78" ] && echo kept || echo gone)"
SH
out="$(bash "$TMP/m2.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O17" 2>&1)"
case "$out" in *"alive=yes"*"count=1"*"close_rc=1"*"record=kept"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a PARSEABLE but drifted tree shape is UNKNOWN too (alive, counted, close unproven, record kept)" $rc

echo
echo "── N) a worker the CENSUS sees but this box has no RECORD of is still reaped ──"
# ⛔ The census resolves a record-less `wt-<worker>` workspace on purpose (a wiped $O/state, a lane from
# an older harness). `wt_close` used to address only tmux in that case, so such a worker held its slot
# forever and logged "could NOT be proven gone" every cycle.
cat > "$TMP/n1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_LOG="$4"; : > "$CMUX_LOG"
T="$O/tree"
printf '%s\n' '{"workspaces":[{"id":"ws_lane9","name":"wt-lane-9"}],"screens":[{"id":"s1","workspace_id":"ws_lane9","layout":{"root":{"tab_ids":["t1"]}}}],"tabs":[{"id":"t1","content_id":"term_x"}],"terminals":[{"id":"term_x","running":true}]}' > "$T.1"
printf '%s\n' '{"workspaces":[],"screens":[],"tabs":[],"terminals":[]}' > "$T.last"
# phase 1: the daemon answers the same thing every time
export CMUX_TREE_RAW="$(cat "$T.1")"
. "$1"
echo "alive=$(wt_alive lane-9 && echo yes || echo no)"
echo "count=$(wt_count lane-)"
# phase 2: the close reads TWICE (once to resolve the surface, once to verify it is gone)
unset CMUX_TREE_RAW; export CMUX_TREE_SEQ="$T"
wt_close lane-9; echo "close_rc=$?"
SH
out="$(bash "$TMP/n1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O16" "$TMP/cmux16.log" 2>&1)"
case "$out" in *"alive=yes"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "a record-less durable terminal is seen by the census" $rc
case "$out" in *"count=1"*) rc=0 ;; *) rc=1;; esac
ck "…and counted against the cap" $rc
grep -q 'CMUX terminal close term_x' "$TMP/cmux16.log" && rc=0 || { rc=1; cat "$TMP/cmux16.log"; }
ck "…and the reap closes its TERMINAL, resolved by the workspace name" $rc
grep -q 'CMUX workspace rm ws_lane9' "$TMP/cmux16.log" && rc=0 || rc=1
ck "…and removes that workspace" $rc
case "$out" in *"close_rc=0"*) rc=0 ;; *) rc=1; echo "      $out";; esac
ck "…reporting a VERIFIED close (the second read says it is gone)" $rc

echo
echo "── O) the PRINTED table carries WORKERS, not the census's internal key spaces ──"
# ⛔ The probe resolves a worker two ways (`w:<worker>`, `t:<terminal-id>`) and the table is what every
# consumer reads. Those internal rows leaked into the printed table, so `report.sh` counted one cmux
# worker as three "sessions" — the exact surface an operator reads to answer "is this box busy".
cat > "$TMP/o1.sh" <<'SH'
set -u
PATH="$2:$PATH"; O="$3"; WT_DIR="$O/state"; WT_TABLE_TTL=0; mkdir -p "$WT_DIR"
export CMUX_TREE_JSON='{"workspaces":[{"id":"ws_a","name":"wt-lane-1"},{"id":"ws_b","name":"wt-lane-2"}],"screens":[{"id":"sa","workspace_id":"ws_a","layout":{"root":{"tab_ids":["ta"]}}},{"id":"sb","workspace_id":"ws_b","layout":{"root":{"tab_ids":["tb"]}}}],"tabs":[{"id":"ta","content_id":"term_a"},{"id":"tb","content_id":"term_b"}],"terminals":[{"id":"term_a","running":true},{"id":"term_b","running":true}]}'
. "$1"
echo "--- table:"
wt_table
SH
out="$(bash "$TMP/o1.sh" "$LIB" "$TMP/bin-cmux" "$TMP/O18" 2>&1)"
# ⛔ `sed '1,/PATTERN/d'` is NOT "skip to the marker": when the pattern matches on line 1, the range
# has no second match and GNU sed deletes to EOF (measured — it produced zero rows from a full table).
rows="$(printf '%s\n' "$out" | awk 'f && NF {print} /^--- table:$/ {f=1}')"
[ "$(printf '%s\n' "$rows" | wc -l | tr -d ' ')" = "2" ] && rc=0 || { rc=1; printf '      rows=[%s] out=[%s]\n' "$rows" "$out"; }
ck "two durable-terminal workers print TWO rows (not six)" $rc
grep -qE '^[wt]:' <<<"$rows" && rc=1 || rc=0
ck "…and no internal \`w:\`/\`t:\` key row leaks into the printed table" $rc
printf '%s\n' "$rows" | awk -F'\t' '$1=="lane-1" && $2=="alive"{f=1} END{exit f?0:1}' && rc=0 || rc=1
ck "…the rows are the worker names with their verdict" $rc

echo
echo "── H) the controller's capacity probes answer on BOTH platforms (agent-infra#1702) ──"
# The SHIPPED helpers, extracted from orch-loop.sh — not a copy. `is_num` comes with them because the
# mtime probe validates its own answer with it.
{ grep -m1 '^is_num() {' "$LOOP"; sed -n '/^file_mtime_epoch() {/,/^}/p' "$LOOP"; } > "$TMP/mtime.sh"
sed -n '/^load1() {/,/^}/p' "$LOOP" > "$TMP/load1.sh"
sed -n '/^swap_usage_mb() {/,/^}/p' "$LOOP" > "$TMP/swap.sh"
need() { [ -s "$1" ] && return 0; ck "$2" 1; return 1; }
: > "$TMP/probe.log"; touch -t 202601010000 "$TMP/probe.log"
want="$(date -r "$TMP/probe.log" +%s)"
# (1) the host's own shape — GNU on a Linux cell, BSD on the operator's Mac.
got="$(bash -c ". '$TMP/mtime.sh'; file_mtime_epoch '$TMP/probe.log'")"
[ "$got" = "$want" ] && rc=0 || { rc=1; echo "      host got '$got' want '$want'"; }
ck "file_mtime_epoch(): the HOST's stat shape returns the mtime (got '${got:-<empty>}')" $rc
# (2) the macOS SHAPE: `stat -c %Y` fails and only `stat -f %m` answers. Unreachable on a Linux CI
# host without this stub, and it is the shape whose failure aborts the controller one cycle in.
mkdir -p "$TMP/bsdonly"
cat > "$TMP/bsdonly/stat" <<'SH'
#!/usr/bin/env bash
# BSD stat: only `-f %m <file>` answers; every GNU form fails (as BSD's does, cleanly).
[ "${1:-}" = "-f" ] && [ "${2:-}" = "%m" ] && { date -r "${3:-}" +%s; exit $?; }
exit 1
SH
chmod +x "$TMP/bsdonly/stat"
got="$(PATH="$TMP/bsdonly:$PATH" bash -c ". '$TMP/mtime.sh'; file_mtime_epoch '$TMP/probe.log'")"
[ "$got" = "$want" ] && rc=0 || { rc=1; echo "      bsd got '$got' want '$want'"; }
ck "file_mtime_epoch(): the macOS shape (stat -f %m) returns the SAME value (got '${got:-<empty>}')" $rc
# (3) both shapes unreadable => no value at all. A guessed age reads as a healthy worker.
got="$(PATH="$TMP/bsdonly:$PATH" bash -c ". '$TMP/mtime.sh'; file_mtime_epoch '$TMP/nope.log' && echo ZERO || echo NONZERO")"
[ "$got" = "NONZERO" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "file_mtime_epoch(): unreadable fails to a non-zero rc instead of guessing" $rc
# (4) LOAD: /proc/loadavg field 1 on Linux, sysctl vm.loadavg field 2 on macOS.
printf '9.75 1.00 2.00 1/9 42\n' > "$TMP/loadavg"
got="$(bash -c ". '$TMP/load1.sh'; load1 '$TMP/loadavg'")"
[ "$got" = "9" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "load1(): the Linux path yields the 1-min load (field 1) — '${got:-<empty>}'" $rc
got="$(bash -c "sysctl() { echo '{ 8.20 7.70 7.10 }'; }; . '$TMP/load1.sh'; load1 '$TMP/no-such-loadavg'")"
[ "$got" = "8" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "load1(): the macOS path yields the 1-min load (field 2) — '${got:-<empty>}'" $rc
# (5) SWAP: /proc/meminfo kB on Linux, sysctl vm.swapusage on macOS. Both must return "<free> <total>".
printf 'MemTotal: 16000000 kB\nSwapTotal: 2048000 kB\nSwapFree: 1024000 kB\n' > "$TMP/meminfo"
got="$(bash -c ". '$TMP/swap.sh'; swap_usage_mb '$TMP/meminfo'")"
[ "$got" = "1000 2000" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "swap_usage_mb(): the Linux path yields <free> <total> MB — '${got:-<empty>}'" $rc
got="$(bash -c "sysctl() { echo 'total = 2048.00M  used = 1.00M  free = 2047.00M'; }; . '$TMP/swap.sh'; swap_usage_mb '$TMP/no-such-meminfo'")"
[ "$got" = "2047 2048" ] && rc=0 || { rc=1; echo "      got '$got'"; }
ck "swap_usage_mb(): the macOS path yields <free> <total> MB — '${got:-<empty>}'" $rc

echo
echo "── P) the module INITIALISES under bash 3.2 — no heredoc inside a command substitution (#2248) ──"
# ⛔ WHY THIS TEST IS TEXTUAL, AND WHY A LINUX-ONLY CI NEEDS IT.
# Apple ships bash 3.2.57 (GPLv2). Under it, a heredoc NESTED INSIDE A COMMAND SUBSTITUTION is
# mis-parsed, in two measured ways (both reproduced on 3.2.57 before this gate was written):
#   1. the quoted delimiter is NOT honoured, so a single quote anywhere in the body opens an
#      unterminated string — `line N: unexpected EOF while looking for matching `''` — and the rest
#      of the file is swallowed by the parse;
#   2. the WORDS OF THE HEREDOC BODY are executed as commands.
# The shipped `WT_TREE_PY="$(cat <<'PY' … PY)"` did both: it executed a COMMENT as a command (the
# body contains `worker's`), then died on `WT_TREE_PY: unbound variable`, and every verb below it was
# never defined — the controller died AT SOURCE TIME on macOS while `launchctl` and `harness verify`
# both said GREEN (measured: `controller … alive but the heartbeat is 3652s old` for an hour).
# `bash -n` PASSES on the broken form: it is a runtime mis-parse, not a syntax error. And GitHub's
# runners are Linux with bash 5.x, which parses the construct CORRECTLY — so the box that breaks
# cannot run this file, and the box that runs this file cannot observe the break. The parse is simply
# unavailable to CI at ANY depth of testing, which leaves one honest way to pin it: assert the
# CONSTRUCT is absent, and separately drive the OBSERVABLE it destroyed (the two Python programs are
# non-empty after a source). Everything below is non-vacuous — three synthetic broken fixtures are
# fed through the same predicate, and the startup GUARD is EXECUTED, not grepped for.
#
# The predicate is per-file (never a word-split list), always quotes its operands, forces the
# filename prefix with -H, and answers SCANNER-ERROR instead of silence when it cannot scan — so it
# fails CLOSED on a path with a space, an empty file list, and a single-file directory alike.
_hh_hits() { # argv: files → one "file:line:text" per hit; never reads stdin, never silently empty
  local f
  [ "$#" -gt 0 ] || { printf 'SCANNER-ERROR: no files to scan\n'; return 0; }
  for f in "$@"; do
    [ -f "$f" ] || { printf 'SCANNER-ERROR: cannot scan %s\n' "$f"; continue; }
    # the single-line shapes, whitespace-tolerant (`$(cat <<`, `$( cat<<`, …), minus whole-line comments
    grep -Hn -E '\$\([[:space:]]*cat[[:space:]]*<<' -- "$f" | grep -vE ':[0-9]+:[[:space:]]*#'
    # the wrapped shape: `$(` ending a line, `cat <<` opening the next
    awk 'p ~ /\$\([[:space:]]*$/ && $0 ~ /^[[:space:]]*cat[[:space:]]*<</ { printf "%s:%d:%s\n", FILENAME, NR, $0 } { p = $0 }' "$f"
  done
}
harness_sh=()
for _f in "$HERE"/*.sh; do
  case "$_f" in *.test.sh) continue ;; esac   # a suite carries the shape as TEXT on purpose; no controller sources one
  harness_sh+=("$_f")
done
hits="$(_hh_hits "${harness_sh[@]}")"
[ -z "$hits" ] && rc=0 || { rc=1; printf '      %s\n' "$hits"; }
ck "no shipped harness module puts a heredoc inside a command substitution (the shape bash 3.2 executes)" $rc

# The observable that regressed: source the module and read the two variables the census feeds to
# `python3 -c`. An empty program is not a loud failure — `python3 -c ''` exits 0 and prints nothing,
# which in this module reads EXACTLY like "no workers": the caps stop binding and a busy box reports
# an idle controller. So assert non-empty, and name the program in the failure.
src_out="$(set -u; . "$LIB" 2>&1; echo "tree=${#WT_TREE_PY} ws=${#WT_WS_PY}")"
case "$src_out" in
  *"tree=0 "*) rc=1 ;;
  *"ws=0"*) rc=1 ;;
  *"tree="*"ws="*) rc=0 ;;
  *) rc=1 ;;
esac
ck "sourcing the module leaves WT_TREE_PY and WT_WS_PY NON-EMPTY — '$(printf '%s' "$src_out" | tr '\n' ' ')'" $rc
# …and it must not have leaked the parser's damage into the log: a bash 3.2 mis-parse prints
# `command not found` / `unexpected EOF` / `unbound variable` lines that a caller redirecting to a
# log would swallow.
case "$src_out" in
  *"command not found"*|*"unbound variable"*|*"syntax error"*|*"unexpected EOF"*)
    rc=1; printf '      %s\n' "$src_out" ;;
  *) rc=0 ;;
esac
ck "…and sourcing emits no command-not-found / unbound-variable / syntax-error / unexpected-EOF" $rc

# ⛔ THE STARTUP GUARD IS EXECUTED, NOT GREPPED FOR. Asserting the NAME appears in orch-loop.sh was a
# vacuous gate: the file's own prose explains the guard and mentions both variables, so DELETING the
# guard loop left that assertion green (measured), and dropping `WT_TREE_PY` from the loop while
# keeping `WT_WS_PY` left BOTH green — i.e. the check could not see the one variable whose emptiness
# produced the outage. So: extract the guard verbatim and RUN it, once per variable. It must exit 78
# AND name the empty variable.
awk '/^for _wt_py in WT_TREE_PY WT_WS_PY; do$/,/^done$/' "$LOOP" > "$TMP/wt-guard.sh"
[ -s "$TMP/wt-guard.sh" ] && rc=0 || { rc=1; echo "      orch-loop.sh no longer carries the WT_TREE_PY/WT_WS_PY startup guard"; }
ck "orch-loop.sh still carries the WT_TREE_PY/WT_WS_PY startup guard block" $rc
_guard() { # _guard <WT_TREE_PY> <WT_WS_PY> → "rc=<n>|<output>"
  bash -c 'O=/x; WT_MOD=/x/worker-terminal.sh; WT_TREE_PY="$2"; WT_WS_PY="$3"
           . "$1"; echo "rc=0|UNREACHABLE"' _ "$TMP/wt-guard.sh" "$1" "$2" 2>&1
}
g="$(_guard abc def)"
case "$g" in *UNREACHABLE*) rc=0 ;; *) rc=1; printf '      %s\n' "$g" ;; esac
ck "the guard PASSES when both programs are populated (it is not a blanket refusal)" $rc
for _gv in WT_TREE_PY WT_WS_PY; do
  if [ "$_gv" = WT_TREE_PY ]; then g="$(_guard "" def)"; else g="$(_guard abc "")"; fi
  case "$g" in
    *UNREACHABLE*) rc=1; echo "      an empty $_gv did NOT stop the controller" ;;
    *"$_gv is EMPTY"*) rc=0 ;;
    *) rc=1; printf '      %s\n' "$g" ;;
  esac
  ck "an EMPTY $_gv stops the controller at startup, naming $_gv" $rc
done

# NON-VACUITY of the scanner: three synthetic fixtures carrying the three shapes that break 3.2 —
# including the apostrophe, which is what makes the delimiter-quoting failure real rather than
# hypothetical (a fixture WITHOUT one sources fine on 3.2 and proves nothing; measured).
{ printf '%s\n' 'WT_X="$(cat <<'"'"'PY'"'"'' "# it's an apostrophe" 'PY' ')"'
  printf '%s\n' 'WT_Y="$(cat<<'"'"'PY'"'"'' "# no space before the <<" 'PY' ')"'
  printf '%s\n' 'WT_Z="$(' 'cat <<'"'"'PY'"'"'' "# the wrapped shape" 'PY' ')"'
} > "$TMP/broken-shapes.sh"
misses="$(_hh_hits "$TMP/broken-shapes.sh" | grep -c ':')"
[ "$misses" -ge 3 ] && rc=0 || { rc=1; echo "      the scanner found $misses of 3 known-broken shapes"; }
ck "the \$(cat << scan detects ALL THREE broken shapes (non-vacuous: spaced, unspaced, wrapped)" $rc
# …and it fails CLOSED when it cannot scan at all, rather than reporting a clean tree it never read.
case "$(_hh_hits "$TMP"/no-such-dir/*.sh)" in *SCANNER-ERROR*) rc=0 ;; *) rc=1 ;; esac
ck "the scanner reports SCANNER-ERROR when it cannot read its inputs (never a silent pass)" $rc

printf '  %d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
